// lib/services/background_location_service.dart

import 'dart:async';
import 'dart:ui';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_background_service_android/flutter_background_service_android.dart';
import 'package:flutter_background_service_ios/flutter_background_service_ios.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:location/location.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import 'package:pigma/backend/schema/structs/positions_struct.dart';
import 'package:pigma/flutter_flow/flutter_flow_util.dart';
import 'package:geolocator/geolocator.dart';
import 'package:geolocator_android/geolocator_android.dart';
import 'package:geolocator_apple/geolocator_apple.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:permission_handler/permission_handler.dart' as permission;

class BackgroundLocationService {
  static BackgroundLocationService? _instance;
  final FlutterBackgroundService _service = FlutterBackgroundService();

  // Singleton pattern
  factory BackgroundLocationService() {
    _instance ??= BackgroundLocationService._internal();
    return _instance!;
  }

  BackgroundLocationService._internal();

  // Canal de notificação para Android
  static const String _notificationChannelId = 'rotasys_channel';
  static const String _notificationChannelName = 'RotaSys Tracking';
  static const String _notificationChannelDescription =
      'RotaSys location tracking service';

  // Chaves para SharedPreferences
  static const String _prefKeyIsTrackingActive = 'bg_tracking_active';
  static const String _prefKeyCpf = 'bg_cpf';
  static const String _prefKeyRouteId = 'bg_routeId';
  static const String _prefKeyFinishViagem = 'bg_finish_viagem';
  static const String _prefKeyLastUpdateTimestamp = 'bg_last_update_timestamp';

  Future<void> initialize() async {
    debugPrint('🔷 Inicializando serviço de localização em segundo plano');

    // Configurar notificações
    final flutterLocalNotificationsPlugin = FlutterLocalNotificationsPlugin();

    // Configuração específica para Android
    if (Platform.isAndroid) {
      final androidImplementation =
          flutterLocalNotificationsPlugin.resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>();
      if (androidImplementation != null) {
        await androidImplementation
            .createNotificationChannel(const AndroidNotificationChannel(
          _notificationChannelId,
          _notificationChannelName,
          description: _notificationChannelDescription,
          importance: Importance.high,
        ));
      }
    }

    // Configuração específica para iOS
    if (Platform.isIOS) {
      await flutterLocalNotificationsPlugin.initialize(
        const InitializationSettings(
          iOS: DarwinInitializationSettings(
            requestAlertPermission: true,
            requestBadgePermission: true,
            requestSoundPermission: true,
            requestProvisionalPermission: true, // Importante para iOS
          ),
          android: AndroidInitializationSettings('app_icon'),
        ),
      );

      // Solicitar permissão de notificação no iOS explicitamente
      final darwinImplementation =
          flutterLocalNotificationsPlugin.resolvePlatformSpecificImplementation<
              IOSFlutterLocalNotificationsPlugin>();
      if (darwinImplementation != null) {
        await darwinImplementation.requestPermissions(
          alert: true,
          badge: true,
          sound: true,
          critical: true, // Para alto nível de prioridade no iOS
        );
      }
    }

    // Configurar serviço em segundo plano
    await _service.configure(
      androidConfiguration: AndroidConfiguration(
        onStart: _onStart,
        autoStart: false,
        isForegroundMode: true,
        foregroundServiceNotificationId: 888,
        notificationChannelId: _notificationChannelId,
        initialNotificationTitle: 'RotaSys Rastreamento',
        initialNotificationContent: 'Rastreando sua localização...',
      ),
      iosConfiguration: IosConfiguration(
        autoStart: false,
        onForeground: _onStart,
        onBackground: _onIosBackground,
        // Importante para atualizações periódicas no iOS
      ),
    );

    // Verificar permissões
    final permissionsGranted = await checkAndRequestPermissions();

    // Verificar se o serviço foi inicializado anteriormente via SharedPreferences
    final firstCheckResult = await checkAndRestartTracking();

    // Se a primeira verificação não encontrou nada, agendar a segunda
    if (!firstCheckResult) {
      Timer(const Duration(seconds: 3), () async {
        debugPrint('🔄 Executando verificação adicional após 3 segundos');
        final secondCheckResult = await _checkForActiveTripsFromAppState();

        // Se a segunda verificação também não encontrou nada, agendar a terceira
        if (!secondCheckResult) {
          Timer(const Duration(seconds: 57), () async {
            // 57 segundos para totalizar 1 minuto desde o início
            debugPrint('🔄 Executando verificação final após 1 minuto');
            final thirdCheckResult = await _checkForActiveTripsFromAppState();

            // NOVO: Se a terceira verificação também não encontrou nada, agendar a quarta (após 5 minutos)
            if (!thirdCheckResult) {
              Timer(const Duration(minutes: 4), () async {
                // 4 minutos para totalizar 5 minutos desde o início (1 min + 4 min)
                debugPrint('🔄 Executando verificação extra após 5 minutos');
                await _checkForActiveTripsFromAppState();
              });
            }
          });
        }
      });
    }
  }

  Future<bool> checkAndRequestPermissions() async {
    try {
      if (Platform.isIOS) {
        // Requisições de permissão específicas para iOS
        var locationAlways = await permission.Permission.locationAlways.status;
        if (locationAlways != permission.PermissionStatus.granted) {
          debugPrint(
              '🔶 Solicitando permissão de localização sempre ativa no iOS');

          // Primeiro pedimos a permissão de uso enquanto o app está em uso
          var locationWhenInUse =
              await permission.Permission.locationWhenInUse.request();
          if (locationWhenInUse != permission.PermissionStatus.granted) {
            debugPrint(
                '❌ Permissão de localização durante uso não concedida no iOS');
            return false;
          }

          // Depois pedimos a permissão de uso em segundo plano ("always")
          locationAlways = await permission.Permission.locationAlways.request();
          if (locationAlways != permission.PermissionStatus.granted) {
            debugPrint(
                '❌ Permissão de localização em segundo plano não concedida no iOS');
            return false;
          }
        }

        // Verificar também notificações
        var notification = await permission.Permission.notification.status;
        if (notification != permission.PermissionStatus.granted) {
          notification = await permission.Permission.notification.request();
        }

        debugPrint('🔷 Permissões de localização iOS: $locationAlways');
      } else {
        // Código existente para Android
        bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
        if (!serviceEnabled) {
          return false;
        }

        LocationPermission permission = await Geolocator.checkPermission();
        if (permission == LocationPermission.denied) {
          permission = await Geolocator.requestPermission();
          if (permission == LocationPermission.denied) {
            return false;
          }
        }

        if (permission == LocationPermission.deniedForever) {
          return false;
        }
      }

      // Configurar o Location para ambas plataformas
      final Location location = Location();
      bool backgroundEnabled = await location.isBackgroundModeEnabled();
      if (!backgroundEnabled) {
        backgroundEnabled = await location.enableBackgroundMode(enable: true);
      }

      return true;
    } catch (e) {
      debugPrint('❌ Erro ao verificar permissões: $e');
      return false;
    }
  }

  @pragma('vm:entry-point')
  static Future<bool> _onIosBackground(ServiceInstance service) async {
    debugPrint('🔷 _onIosBackground chamado às ${DateTime.now()}');

    // Necessário para qualquer código que precise do Flutter
    WidgetsFlutterBinding.ensureInitialized();
    DartPluginRegistrant.ensureInitialized();

    // Verificar se o rastreamento está ativo
    final prefs = await SharedPreferences.getInstance();
    final isActive = prefs.getBool(_prefKeyIsTrackingActive) ?? false;

    if (isActive) {
      try {
        final cpf = prefs.getString(_prefKeyCpf) ?? '';
        final routeId = prefs.getString(_prefKeyRouteId) ?? '';

        if (cpf.isNotEmpty && routeId.isNotEmpty) {
          // Obter localização atual
          final locationData = await _getLocationSafely();

          if (locationData != null &&
              locationData.latitude != null &&
              locationData.longitude != null) {
            // Criar estrutura de posição e salvar
            final DateTime dataHora = DateTime.now();
            final DateTime dataHoraAjustada = dataHora
                .subtract(dataHora.timeZoneOffset)
                .subtract(const Duration(hours: 3));

            final finishViagem = prefs.getBool(_prefKeyFinishViagem) ?? false;

            final position = PositionsStruct(
              cpf: cpf,
              routeId: int.tryParse(routeId),
              latitude: locationData.latitude,
              longitude: locationData.longitude,
              date: dataHoraAjustada,
              finish: false,
              finishViagem: finishViagem,
            );

            // Tentar enviar ou salvar
            final sent = await _sendLocationToApi(position);
            if (!sent) {
              await _savePositionForSync(position);
            }

            // Atualizar timestamp
            await prefs.setInt(_prefKeyLastUpdateTimestamp,
                DateTime.now().millisecondsSinceEpoch);
          }
        }
      } catch (e) {
        debugPrint('❌ Erro ao processar localização em background iOS: $e');
      }
    }

    // É crucial retornar true para o iOS manter o serviço em background
    return true;
  }

  // Modificado para retornar se encontrou e iniciou uma viagem
  Future<bool> checkAndRestartTracking() async {
    debugPrint('🔄 Verificando se o serviço deve ser reiniciado');

    final prefs = await SharedPreferences.getInstance();
    final isActive = prefs.getBool(_prefKeyIsTrackingActive) ?? false;

    debugPrint('🔄 Rastreamento ativo nas preferências: $isActive');

    if (isActive) {
      final cpf = prefs.getString(_prefKeyCpf) ?? '';
      final routeId = prefs.getString(_prefKeyRouteId) ?? '';
      final finishViagem = prefs.getBool(_prefKeyFinishViagem) ?? false;

      debugPrint(
          '🔄 Dados da rota: CPF=$cpf, RouteId=$routeId, FinishViagem=$finishViagem');

      if (cpf.isNotEmpty && routeId.isNotEmpty) {
        final restarted = await startLocationUpdates(
          cpf: cpf,
          routeId: routeId,
          finishViagem: finishViagem,
        );

        debugPrint('🔄 Rastreamento reiniciado com sucesso: $restarted');
        return true; // Encontrou e iniciou uma viagem
      } else {
        debugPrint(
            '❗ Não foi possível reiniciar rastreamento: dados incompletos');
      }
    } else {
      debugPrint('ℹ️ Não há rastreamento ativo para reiniciar');
    }

    return false; // Não encontrou viagem ativa nas preferências
  }

  // NOVO MÉTODO: Verificar trips ativas no AppState (retorna se iniciou uma viagem)
  Future<bool> _checkForActiveTripsFromAppState() async {
    try {
      final appState = FFAppState();
      final isServiceRunning = await isRunning();
      final prefs = await SharedPreferences.getInstance();
      final isTrackingActive = prefs.getBool(_prefKeyIsTrackingActive) ?? false;

      debugPrint(
          '🔄 Verificação agendada: isServiceRunning=$isServiceRunning, isTrackingActive=$isTrackingActive');
      debugPrint(
          '🔄 Estado da viagem: hasRouteId=${appState.routeSelected.hasRouteId()}, hasStopId=${appState.stopInProgress.hasStopId()}, viagemFinalizada=${appState.viagemFinalizada}');

      // Se o serviço não estiver ativo mas existe uma viagem em andamento no estado do app
      if (!isTrackingActive &&
          !isServiceRunning &&
          appState.routeSelected.hasRouteId() &&
          appState.stopInProgress.hasStopId() &&
          !appState.viagemFinalizada) {
        debugPrint(
            '✅ Viagem ativa detectada no AppState que não estava sendo rastreada');

        // Iniciar o rastreamento com base nos dados do AppState
        final result = await startLocationUpdates(
          cpf: appState.cpf,
          routeId: appState.routeSelected.routeId.toString(),
          finishViagem: false,
        );

        debugPrint(
            '✅ Rastreamento iniciado automaticamente para viagem existente: $result');
        return true; // Encontrou e iniciou uma viagem
      } else {
        debugPrint(
            'ℹ️ Sem viagens ativas para iniciar ou rastreamento já ativo');
      }
    } catch (e) {
      // Apenas registrar o erro sem interromper a inicialização normal
      debugPrint('⚠️ Erro ao verificar viagem ativa no AppState: $e');
    }

    return false; // Não encontrou viagem ativa ou falhou ao iniciar
  }

  static Future<LocationData?> _getLocationSafely() async {
    try {
      debugPrint("🔶 Tentando obter localização no serviço");

      // Configurações específicas para iOS para melhorar a confiabilidade
      if (Platform.isIOS) {
        try {
          // No iOS, o Geolocator com configurações específicas para iOS
          final locationSettings = AppleSettings(
            activityType: ActivityType
                .automotiveNavigation, // Melhor para rastreamento de veículos
            distanceFilter: 0, // Capturar qualquer movimento
            pauseLocationUpdatesAutomatically:
                false, // Não pausar automaticamente
            showBackgroundLocationIndicator:
                true, // Indicador de localização em background
            allowBackgroundLocationUpdates:
                true, // Habilitar atualizações em background
          );

          // Obter posição atual
          final position = await Geolocator.getCurrentPosition(
            locationSettings: locationSettings,
          );

          debugPrint(
              '📍 Localização iOS obtida: Lat=${position.latitude}, Lng=${position.longitude}');

          return LocationData.fromMap({
            'latitude': position.latitude,
            'longitude': position.longitude,
            'accuracy': position.accuracy.toDouble(),
            'altitude': position.altitude,
            'speed': position.speed,
            'speed_accuracy': position.speedAccuracy.toDouble(),
            'heading': position.heading,
            'time': (position.timestamp?.millisecondsSinceEpoch ??
                    DateTime.now().millisecondsSinceEpoch)
                .toDouble(),
            'is_mocked': position.isMocked ? 1.0 : 0.0,
          });
        } catch (iosError) {
          debugPrint('⚠️ Erro ao obter localização iOS: $iosError');

          // Tentar obter a última posição conhecida
          try {
            final lastPosition = await Geolocator.getLastKnownPosition();
            if (lastPosition != null) {
              debugPrint(
                  '📍 Última localização iOS conhecida: Lat=${lastPosition.latitude}, Lng=${lastPosition.longitude}');
              return LocationData.fromMap({
                'latitude': lastPosition.latitude,
                'longitude': lastPosition.longitude,
                'accuracy': lastPosition.accuracy.toDouble(),
                'altitude': lastPosition.altitude,
                'speed': lastPosition.speed,
                'speed_accuracy': lastPosition.speedAccuracy.toDouble(),
                'heading': lastPosition.heading,
                'time': (lastPosition.timestamp?.millisecondsSinceEpoch ??
                        DateTime.now().millisecondsSinceEpoch)
                    .toDouble(),
                'is_mocked': lastPosition.isMocked ? 1.0 : 0.0,
              });
            }
          } catch (e) {
            debugPrint('⚠️ Erro ao obter última localização iOS: $e');
          }
        }
      } else {
        // CÓDIGO ANDROID ORIGINAL - Mantido intacto
        try {
          late LocationSettings locationSettings;

          locationSettings = AndroidSettings(
              distanceFilter: 0,
              forceLocationManager: false,
              intervalDuration: const Duration(seconds: 5),
              foregroundNotificationConfig: const ForegroundNotificationConfig(
                notificationText:
                    "RotaSys continuará rastreando sua localização mesmo em segundo plano",
                notificationTitle: "RotaSys Ativo",
                enableWakeLock: true,
              ));

          // Obter posição atual com as configurações apropriadas
          final position = await Geolocator.getCurrentPosition(
            locationSettings: locationSettings,
          );

          debugPrint(
              '📍 Localização obtida com Geolocator: Lat=${position.latitude}, Lng=${position.longitude}');

          return LocationData.fromMap({
            'latitude': position.latitude,
            'longitude': position.longitude,
            'accuracy': position.accuracy.toDouble(),
            'altitude': position.altitude,
            'speed': position.speed,
            'speed_accuracy': position.speedAccuracy.toDouble(),
            'heading': position.heading,
            'time': (position.timestamp?.millisecondsSinceEpoch ??
                    DateTime.now().millisecondsSinceEpoch)
                .toDouble(),
            'is_mocked': position.isMocked ? 1.0 : 0.0,
          });
        } catch (directError) {
          debugPrint(
              '⚠️ ERRO ao obter localização com Geolocator: $directError');

          // Tentar obter a última posição conhecida
          try {
            final lastPosition = await Geolocator.getLastKnownPosition();

            if (lastPosition != null) {
              debugPrint(
                  '📍 Última localização conhecida: Lat=${lastPosition.latitude}, Lng=${lastPosition.longitude}');

              return LocationData.fromMap({
                'latitude': lastPosition.latitude,
                'longitude': lastPosition.longitude,
                'accuracy': lastPosition.accuracy.toDouble(),
                'altitude': lastPosition.altitude,
                'speed': lastPosition.speed,
                'speed_accuracy': lastPosition.speedAccuracy.toDouble(),
                'heading': lastPosition.heading,
                'time': (lastPosition.timestamp?.millisecondsSinceEpoch ??
                        DateTime.now().millisecondsSinceEpoch)
                    .toDouble(),
                'is_mocked': lastPosition.isMocked ? 1.0 : 0.0,
              });
            }
          } catch (lastPosError) {
            debugPrint(
                '⚠️ Erro ao obter última localização conhecida: $lastPosError');
          }
        }
      }

      // Código de fallback existente - Mantido intacto
      final prefs = await SharedPreferences.getInstance();
      final lastLatitude = prefs.getDouble('bg_last_latitude');
      final lastLongitude = prefs.getDouble('bg_last_longitude');

      if (lastLatitude != null && lastLongitude != null) {
        debugPrint(
            '📍 Usando localização armazenada: Lat=$lastLatitude, Lng=$lastLongitude');

        return LocationData.fromMap({
          'latitude': lastLatitude,
          'longitude': lastLongitude,
          'accuracy': 0.0,
          'altitude': 0.0,
          'speed': 0.0,
          'speed_accuracy': 0.0,
          'heading': 0.0,
          'time': DateTime.now().millisecondsSinceEpoch.toDouble(),
          'is_mocked': 0.0,
        });
      }

      debugPrint('⚠️ Nenhuma localização disponível');
      return null;
    } catch (e) {
      debugPrint('❌ Erro ao obter localização com segurança: $e');
      return null;
    }
  }

  static Future<bool> _sendLocationToApi(PositionsStruct position) async {
    try {
      // Inicializar dados de localização para pt_BR (importante!)
      await initializeDateFormatting('pt_BR', null);

      // URL correta da API
      const apiUrl =
          'https://lakre.pigmadesenvolvimentos.com.br:10529/apis/PostPosition';

      // Cabeçalhos necessários conforme documentação
      Map<String, String> headers = {
        'Content-Type': 'application/x-www-form-urlencoded',
        'User-Agent': 'com.pigmadesenvolvimentos.lakretracking',
        'Authorization':
            'JlEIJjmoLMKtkpxDqOzWAGpkTePDQonu', // API Key dos documentos
      };

      // Formatar data no formato correto
      final formattedDate = dateTimeFormat(
        'yyyy-MM-dd HH:mm:ss',
        position.date,
        locale: 'pt_BR',
      );

      // Preparar parâmetros no formato x-www-form-urlencoded (não JSON)
      final Map<String, String> params = {
        'cpf': position.cpf ?? '',
        'routeId': (position.routeId ?? 0).toString(),
        'latitude': (position.latitude ?? 0).toString(),
        'longitude': (position.longitude ?? 0).toString(),
        'isFinished': (position.finish ?? false).toString(),
        'infoDt': formattedDate,
      };

      debugPrint('🔄 Enviando dados para API: $params');
      debugPrint('🔄 URL da API: $apiUrl');

      // Codificar parâmetros para x-www-form-urlencoded
      final encodedParams = params.entries
          .map((e) =>
              '${Uri.encodeComponent(e.key)}=${Uri.encodeComponent(e.value)}')
          .join('&');

      // Fazer requisição HTTP com formato x-www-form-urlencoded
      final response = await http
          .post(
            Uri.parse(apiUrl),
            headers: headers,
            body: encodedParams,
          )
          .timeout(const Duration(seconds: 10));

      // Verificar resposta
      if (response.statusCode >= 200 && response.statusCode < 300) {
        debugPrint(
            '✅ Localização enviada com sucesso para a API: ${response.statusCode}');
        return true;
      } else {
        debugPrint(
            '❌ Erro ao enviar localização: ${response.statusCode} - ${response.body}');
        return false;
      }
    } catch (e) {
      debugPrint('❌ Exceção ao enviar localização: $e');

      return false;
    }
  }

  static Future<void> _trySyncPendingPositions() async {
    final prefs = await SharedPreferences.getInstance();
    List<String> positionsJson = prefs.getStringList('ff_positions') ?? [];

    if (positionsJson.isEmpty) {
      debugPrint('ℹ️ Sem posições pendentes para sincronizar');
      return;
    }

    debugPrint(
        '🔄 Tentando sincronizar ${positionsJson.length} posições pendentes');

    // Tentar sincronizar até 3 posições por vez (para evitar sobrecarga)
    int maxToSync = 3;
    int currentIndex = 0;

    while (currentIndex < positionsJson.length && currentIndex < maxToSync) {
      try {
        // Obter a primeira posição da lista
        final positionJson = positionsJson[0]; // Sempre pegar a primeira
        final position =
            PositionsStruct.fromSerializableMap(jsonDecode(positionJson));

        // Tentar enviar para a API
        final success = await _sendLocationToApi(position);

        if (success) {
          // Se foi bem sucedido, remover da lista
          positionsJson.removeAt(0);
          await prefs.setStringList('ff_positions', positionsJson);
          debugPrint('✅ Posição pendente sincronizada com sucesso');
        } else {
          // Se falhou, interromper tentativas
          debugPrint(
              '❌ Falha ao sincronizar posição pendente, tentando novamente depois');
          break;
        }

        currentIndex++;
      } catch (e) {
        debugPrint('❌ Erro ao processar posição pendente: $e');
        break;
      }
    }

    // Atualizar contagem de posições salvas
    await prefs.setInt('bg_saved_positions_count', positionsJson.length);
    debugPrint('ℹ️ Restam ${positionsJson.length} posições pendentes');
  }

  static Future<void> _savePositionForSync(PositionsStruct position) async {
    final prefs = await SharedPreferences.getInstance();

    try {
      // Recuperar lista atual de posições
      List<String> positionsJson = prefs.getStringList('ff_positions') ?? [];

      // Adicionar nova posição
      positionsJson.add(position.serialize());

      // Salvar lista atualizada
      await prefs.setStringList('ff_positions', positionsJson);

      debugPrint(
          '📊 Posição salva para sincronização posterior. Total: ${positionsJson.length}');

      // Salvar informação adicional para recuperação
      await prefs.setInt('bg_saved_positions_count', positionsJson.length);
      await prefs.setInt(
          'bg_last_save_timestamp', DateTime.now().millisecondsSinceEpoch);
    } catch (e) {
      debugPrint('❌ Erro ao salvar posição: $e');
    }
  }

  Future<bool> startLocationUpdates({
    required String cpf,
    required String routeId,
    bool finishViagem = false,
  }) async {
    debugPrint(
        '▶️ Solicitação para iniciar rastreamento: CPF=$cpf, RouteId=$routeId, FinishViagem=$finishViagem');

    try {
      // Verificar permissões antes de iniciar
      final permissionsGranted = await checkAndRequestPermissions();
      if (!permissionsGranted) {
        debugPrint('❌ Permissões não concedidas');
        return false;
      }

      // Salvar parâmetros
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefKeyCpf, cpf);
      await prefs.setString(_prefKeyRouteId, routeId);
      await prefs.setBool(_prefKeyFinishViagem, finishViagem);
      await prefs.setBool(_prefKeyIsTrackingActive, true);

      // Configurações específicas para iOS antes de iniciar o serviço
      if (Platform.isIOS) {
        // Configurar o Location para garantir que está habilitado para segundo plano
        final Location location = Location();
        await location.enableBackgroundMode(enable: true);

        // Definir configurações de alta precisão para iOS
        await location.changeSettings(
          interval: 5000, // 5 segundos
          distanceFilter: 0,
        );

        // Obter localização inicial para "aquecer" o sistema
        try {
          final initialLocation = await location.getLocation();
          debugPrint(
              '🔷 Localização inicial iOS: ${initialLocation.latitude}, ${initialLocation.longitude}');
        } catch (e) {
          debugPrint('⚠️ Erro ao obter localização inicial no iOS: $e');
        }
      }

      // Iniciar o serviço
      final serviceStarted = await _service.startService();
      debugPrint('▶️ Serviço iniciado com sucesso: $serviceStarted');
      return serviceStarted;
    } catch (e) {
      debugPrint('❌ Erro ao iniciar serviço: $e');
      return false;
    }
  }

  Future<bool> stopLocationUpdates() async {
    debugPrint('⏹️ Solicitação para parar rastreamento');

    try {
      // Desativar flag de rastreamento
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_prefKeyIsTrackingActive, false);

      // Salvar estatísticas finais
      await prefs.setInt(
          'bg_service_stop_timestamp', DateTime.now().millisecondsSinceEpoch);

      // Tentar parar o serviço diretamente
      _service.invoke('stopService');

      debugPrint('⏹️ Serviço marcado para parar');

      return true;
    } catch (e) {
      debugPrint('❌ Erro ao parar serviço de localização em segundo plano: $e');
      return false;
    }
  }

  Future<bool> isRunning() async {
    final running = await _service.isRunning();
    debugPrint('ℹ️ Serviço está rodando: $running');
    return running;
  }

  Future<Map<String, dynamic>> getServiceStatistics() async {
    try {
      final prefs = await SharedPreferences.getInstance();

      final startTimestamp = prefs.getInt('bg_service_start_timestamp') ?? 0;
      final lastUpdateTimestamp =
          prefs.getInt(_prefKeyLastUpdateTimestamp) ?? 0;
      final totalChecks = prefs.getInt('bg_service_total_checks') ?? 0;
      final successfulUpdates =
          prefs.getInt('bg_service_successful_updates') ?? 0;
      final successfulApiSends = prefs.getInt('bg_successful_api_sends') ?? 0;
      final savedPositionsCount = prefs.getInt('bg_saved_positions_count') ?? 0;

      final now = DateTime.now().millisecondsSinceEpoch;

      return {
        'isRunning': await isRunning(),
        'startTime': startTimestamp > 0
            ? DateTime.fromMillisecondsSinceEpoch(startTimestamp)
            : null,
        'lastUpdateTime': lastUpdateTimestamp > 0
            ? DateTime.fromMillisecondsSinceEpoch(lastUpdateTimestamp)
            : null,
        'runningTimeMinutes':
            startTimestamp > 0 ? (now - startTimestamp) ~/ 60000 : 0,
        'totalChecks': totalChecks,
        'successfulUpdates': successfulUpdates,
        'successfulApiSends': successfulApiSends,
        'successRate': totalChecks > 0
            ? (successfulUpdates / totalChecks * 100).toStringAsFixed(1) + '%'
            : '0%',
        'apiSendRate': successfulUpdates > 0
            ? (successfulApiSends / successfulUpdates * 100)
                    .toStringAsFixed(1) +
                '%'
            : '0%',
        'savedPositionsCount': savedPositionsCount,
        'timeSinceLastUpdateSeconds': lastUpdateTimestamp > 0
            ? (now - lastUpdateTimestamp) ~/ 1000
            : null,
      };
    } catch (e) {
      debugPrint('❌ Erro ao obter estatísticas: $e');
      return {
        'error': e.toString(),
        'isRunning': await isRunning(),
      };
    }
  }

  Future<void> registerBackgroundTask() async {
    if (Platform.isIOS) {
      debugPrint('🔷 Registrando tarefas em segundo plano para iOS');

      try {
        // Obter permissões de localização em segundo plano explicitamente
        final location = Location();
        final hasPermission = await location.hasPermission();

        if (hasPermission == PermissionStatus.denied) {
          final requestResult = await location.requestPermission();
          debugPrint('🔷 Permissão de localização solicitada: $requestResult');

          if (requestResult != PermissionStatus.granted &&
              requestResult != PermissionStatus.grantedLimited) {
            debugPrint('❌ Permissão de localização negada pelo usuário');
            return;
          }
        }

        // Importante: habilitar o modo de background
        final backgroundEnabled =
            await location.enableBackgroundMode(enable: true);
        debugPrint('🔷 Modo de background habilitado: $backgroundEnabled');

        // Obter uma localização inicial para "aquecer" o sistema de permissões
        try {
          final initialLocation = await location.getLocation();
          debugPrint(
              '🔷 Localização inicial obtida para registro: ${initialLocation.latitude}, ${initialLocation.longitude}');
        } catch (e) {
          debugPrint('⚠️ Erro ao obter localização inicial: $e');
        }
      } catch (e) {
        debugPrint('❌ Erro ao registrar tarefas em segundo plano: $e');
      }
    }
  }

  @pragma('vm:entry-point')
  static void _onStart(ServiceInstance service) async {
    debugPrint(
        '🔵 Serviço de localização em segundo plano iniciado às ${DateTime.now()}');

    try {
      WidgetsFlutterBinding.ensureInitialized();
      DartPluginRegistrant.ensureInitialized();

      // Configurar serviço como foreground no Android com prioridade alta
      if (service is AndroidServiceInstance) {
        debugPrint('🔵 Configurando serviço como foreground no Android');

        // Definir como serviço em primeiro plano
        service.setAsForegroundService();

        // Configurar notificação persistente
        await service.setForegroundNotificationInfo(
          title: 'RotaSys Rastreamento Ativo',
          content: 'O rastreamento de localização está ativo em segundo plano',
        );
      }

      // Definir uma variável para rastrear o status de execução
      bool isServiceRunning = true;

      // Registrar manipuladores para comandos recebidos
      service.on('isRunning').listen((event) {
        debugPrint('🔵 Comando isRunning recebido');
        service.invoke('onRunningStatus', {'isRunning': isServiceRunning});
      });

      service.on('stopService').listen((event) {
        debugPrint('🔶 Comando para parar o serviço recebido');
        isServiceRunning = false;
        service.stopSelf();
      });

      service.on('updateNotification').listen((event) {
        if (service is AndroidServiceInstance) {
          debugPrint('🔵 Atualizando notificação');
          service.setForegroundNotificationInfo(
            title: event?['title'] ?? 'RotaSys Rastreamento',
            content: event?['content'] ?? 'Rastreando sua rota...',
          );
        }
      });

      // Inicializar Location de forma isolada para evitar vazamentos
      final location = Location();

      // Configurações específicas por plataforma para Location
      if (Platform.isIOS) {
        await location.enableBackgroundMode(enable: true);
        // No iOS, configuramos um accuracy diferente
        await location.changeSettings(
          interval: 5000,
          distanceFilter: 0,
        );
        debugPrint('🔵 Location configurado para iOS com alta precisão');
      } else {
        await location.enableBackgroundMode(enable: true);
        debugPrint('🔵 Modo de segundo plano do location ativado para Android');
      }

      // Tentar obter localização inicial (para armazenar)
      try {
        final initialLocation = await _getLocationSafely();
        debugPrint(
            '🔵 Localização inicial obtida: Lat=${initialLocation?.latitude}, Lng=${initialLocation?.longitude}');

        // Salvar no SharedPreferences para uso posterior
        final prefs = await SharedPreferences.getInstance();
        if (initialLocation?.latitude != null &&
            initialLocation?.longitude != null) {
          await prefs.setDouble(
              'bg_last_latitude', initialLocation?.latitude ?? 0.0);
          await prefs.setDouble(
              'bg_last_longitude', initialLocation?.longitude ?? 0.0);
        }
      } catch (e) {
        debugPrint('❌ Erro ao obter localização inicial: $e');
      }

      // Criar timer para verificar periodicidade de forma precisa
      int executionCount = 0;
      int successfulLocationUpdates = 0;
      int successfulApiSends = 0;
      final startTime = DateTime.now();

      // Salvar timestamp de início no SharedPreferences para rastreamento
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(
          'bg_service_start_timestamp', startTime.millisecondsSinceEpoch);

      // Intervalo diferente conforme a plataforma - no iOS respeita o requisito de 5 minutos
      final updateInterval = Platform.isIOS
          ? const Duration(
              minutes: 5) // 5 minutos para iOS (conforme requisito)
          : const Duration(
              minutes: 1); // 1 minuto para Android - mantendo como estava

      // Configurar timer para coletar a localização periodicamente
      Timer.periodic(updateInterval, (timer) async {
        final now = DateTime.now();
        executionCount++;

        debugPrint('🟢 Timer executado (#$executionCount) às $now');
        debugPrint(
            '🟢 Tempo desde o início: ${now.difference(startTime).inMinutes} minutos');
        debugPrint(
            '🟢 Atualizações bem-sucedidas: $successfulLocationUpdates de $executionCount (${(successfulLocationUpdates / executionCount * 100).toStringAsFixed(1)}%)');

        // Atualizar SharedPreferences com última execução
        try {
          await prefs.setInt(
              _prefKeyLastUpdateTimestamp, now.millisecondsSinceEpoch);
        } catch (e) {
          debugPrint('⚠️ Não foi possível salvar timestamp: $e');
        }

        // Atualizar notificação para garantir que o serviço continue em foreground
        if (service is AndroidServiceInstance) {
          try {
            bool isForeground = await service.isForegroundService();
            debugPrint('🟢 Serviço está em foreground: $isForeground');

            if (isForeground) {
              await service.setForegroundNotificationInfo(
                title: 'RotaSys Rastreamento Ativo',
                content:
                    'Rastreamento ativo em segundo plano. Atualizando localização...',
              );
            } else {
              debugPrint(
                  '❗ Serviço não está em foreground, tentando restaurar...');
              service.setAsForegroundService();
            }
          } catch (e) {
            debugPrint('❌ Erro ao atualizar notificação: $e');
          }
        }

        // Se o serviço não estiver mais em execução, parar o timer
        if (!isServiceRunning) {
          debugPrint(
              '🔴 Serviço marcado como não em execução, cancelando timer');
          timer.cancel();
          return;
        }

        // Verificar se o rastreamento está ativo
        try {
          final isActive = prefs.getBool(_prefKeyIsTrackingActive) ?? false;

          debugPrint('🟢 Rastreamento ativo nas preferências: $isActive');

          if (!isActive) {
            debugPrint('🔴 Rastreamento marcado como inativo, parando serviço');
            isServiceRunning = false;
            service.stopSelf();
            return;
          }

          // Obter dados da rota
          final cpf = prefs.getString(_prefKeyCpf) ?? '';
          final routeId = prefs.getString(_prefKeyRouteId) ?? '';
          final finishViagem = prefs.getBool(_prefKeyFinishViagem) ?? false;

          debugPrint(
              '🟢 Dados da rota: CPF=$cpf, RouteId=$routeId, FinishViagem=$finishViagem');

          if (cpf.isEmpty || routeId.isEmpty) {
            debugPrint('❗ CPF ou RouteId vazios, pulando atualização');
            return;
          }

          // Obter localização atual usando o método seguro
          final locationData = await _getLocationSafely();

          if (locationData == null ||
              locationData.latitude == null ||
              locationData.longitude == null) {
            debugPrint('❗ Não foi possível obter localização válida');
            return;
          }

          debugPrint(
              '📍 Localização obtida: Latitude=${locationData.latitude}, Longitude=${locationData.longitude}');
          successfulLocationUpdates++;

          // Salvar estatísticas de sucesso
          await prefs.setInt(
              'bg_service_successful_updates', successfulLocationUpdates);
          await prefs.setInt('bg_service_total_checks', executionCount);

          // Criar estrutura de posição
          final DateTime dataHora = DateTime.now();
          final DateTime dataHoraAjustada = dataHora
              .subtract(dataHora.timeZoneOffset)
              .subtract(const Duration(hours: 3));

          final position = PositionsStruct(
            cpf: cpf,
            routeId: int.tryParse(routeId),
            latitude: locationData.latitude,
            longitude: locationData.longitude,
            date: dataHoraAjustada,
            finish: false,
            finishViagem: finishViagem,
          );

          // Tentar enviar diretamente para a API
          final sentSuccessfully = await _sendLocationToApi(position);

          if (sentSuccessfully) {
            // Se o envio foi bem-sucedido
            successfulApiSends++;
            await prefs.setInt('bg_successful_api_sends', successfulApiSends);
            debugPrint(
                '✅ Posição enviada diretamente para API VINDA DA SERVICE');
          } else {
            // Se falhou, salvar para sincronização posterior
            await _savePositionForSync(position);
            debugPrint(
                '⚠️ Não foi possível enviar para API, salvando para depois');
          }

          // Tentar sincronizar posições pendentes
          await _trySyncPendingPositions();

          // Enviar dados para o aplicativo principal (se estiver aberto)
          final Map<String, dynamic> locationUpdateData = {
            'latitude': locationData.latitude,
            'longitude': locationData.longitude,
            'timestamp': DateTime.now().millisecondsSinceEpoch,
            'routeId': routeId,
            'cpf': cpf,
          };

          // Invocar evento para o app principal (se estiver aberto)
          service.invoke('update_location', locationUpdateData);

          // Salvar última localização para recuperação se o serviço for reiniciado
          await prefs.setDouble('bg_last_latitude', locationData.latitude!);
          await prefs.setDouble('bg_last_longitude', locationData.longitude!);
        } catch (e) {
          debugPrint('❌ Erro no timer principal: $e');
        }
      });

      // Se estivermos no Android, garantir que o serviço não seja facilmente encerrado
      if (Platform.isAndroid) {
        debugPrint(
            '🔵 Configurando serviço no Android para evitar que seja encerrado');

        // Registrar receiver para reiniciar o serviço se for encerrado
        service.on('restart').listen((_) async {
          debugPrint('🔄 Recebido comando para reiniciar o serviço');
          // Em vez de chamar service.startService(), use a instância global do serviço
          final FlutterBackgroundService backgroundService =
              FlutterBackgroundService();
          await backgroundService.startService();
        });
      }

      // Se estivermos no iOS, configurações específicas
      if (Platform.isIOS) {
        debugPrint('🔵 Configurando serviço específico para iOS');

        // No iOS, precisamos manter o aplicativo ciente que o serviço está ativo
        Timer.periodic(const Duration(minutes: 10), (timer) {
          if (!isServiceRunning) {
            timer.cancel();
            return;
          }

          debugPrint('🔄 Mantendo serviço iOS ativo');
          service.invoke('keepAlive',
              {'timestamp': DateTime.now().millisecondsSinceEpoch});

          // Importante: No iOS, devemos solicitar periodicamente a localização
          // para manter as permissões de background ativas
          _getLocationSafely().then((location) {
            if (location != null) {
              debugPrint(
                  '📍 Ping de localização iOS: ${location.latitude}, ${location.longitude}');
            }
          });
        });

        // No iOS, também é útil registrar um manipulador para quando o app entrar em background
        service.on('onBackground').listen((event) async {
          debugPrint('🔵 Aplicativo entrou em background no iOS');
          // Garantir que o modo background está habilitado quando o app vai para background
          final location = Location();
          await location.enableBackgroundMode(enable: true);
        });
      }
    } catch (e) {
      debugPrint('💥 Erro fatal no serviço de background: $e');
      service.stopSelf();
    }
  }
}
