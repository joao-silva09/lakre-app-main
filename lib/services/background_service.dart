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

  // URL da API
  static const String _apiUrl =
      'https://api.pigma.com.br/api/v1/position'; // Ajuste para URL correta

  Future<void> initialize() async {
    debugPrint('🔷 Inicializando serviço de localização em segundo plano');

    // Configurar notificações
    final flutterLocalNotificationsPlugin = FlutterLocalNotificationsPlugin();

    final androidImplementation =
        flutterLocalNotificationsPlugin.resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();
    if (androidImplementation != null) {
      await androidImplementation
          .createNotificationChannel(const AndroidNotificationChannel(
        _notificationChannelId,
        _notificationChannelName,
        description: _notificationChannelDescription,
        // Aumentar a importância para HIGH para evitar que o sistema mate o serviço
        importance: Importance.high,
      ));

      debugPrint('🔷 Canal de notificação criado com sucesso');
    }

    // Inicializar o plugin de notificações locais para iOS
    if (Platform.isIOS) {
      await flutterLocalNotificationsPlugin.initialize(
        const InitializationSettings(
          iOS: DarwinInitializationSettings(
            requestAlertPermission: true,
            requestBadgePermission: true,
            requestSoundPermission: true,
          ),
          android: AndroidInitializationSettings('app_icon'),
        ),
      );
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
      ),
    );

    debugPrint('🔷 Serviço configurado com sucesso');

    // Verificar permissões
    final permissionsGranted = await checkAndRequestPermissions();
    debugPrint('🔷 Permissões concedidas: $permissionsGranted');

    // Verificar se o serviço foi inicializado anteriormente
    await checkAndRestartTracking();
  }

  Future<bool> checkAndRequestPermissions() async {
    try {
      // Verificar serviço de localização
      bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        debugPrint('🔶 Serviço de localização não habilitado, solicitando...');
        // Infelizmente não podemos ativar diretamente, precisamos informar o usuário
        return false;
      }

      // Verificar permissão
      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        debugPrint('🔶 Permissão de localização não concedida, solicitando...');
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied) {
          debugPrint('❌ Permissão de localização negada pelo usuário');
          return false;
        }
      }

      if (permission == LocationPermission.deniedForever) {
        debugPrint(
            '❌ Permissão de localização negada permanentemente pelo usuário');
        return false;
      }

      // Verificar e configurar o Location também (para compatibilidade)
      final Location location = Location();

      bool backgroundEnabled = await location.isBackgroundModeEnabled();
      if (!backgroundEnabled) {
        debugPrint(
            '🔶 Modo em segundo plano do Location não habilitado, habilitando...');
        backgroundEnabled = await location.enableBackgroundMode(enable: true);
      }

      debugPrint('✅ Todas as permissões concedidas com sucesso');
      return true;
    } catch (e) {
      debugPrint('❌ Erro ao verificar permissões: $e');
      return false;
    }
  }

  @pragma('vm:entry-point')
  static Future<bool> _onIosBackground(ServiceInstance service) async {
    debugPrint('🔷 _onIosBackground chamado às ${DateTime.now()}');
    WidgetsFlutterBinding.ensureInitialized();
    DartPluginRegistrant.ensureInitialized();
    return true;
  }

  static Future<LocationData?> _getLocationSafely() async {
    try {
      debugPrint("CHEGOU AQUI PARA TENTAR PEGAR A LOCALIZACAO NA SERVICE");

      // Tentar obter localização com Geolocator (funciona em background)
      try {
        // Configurar settings específicos para a plataforma
        late LocationSettings locationSettings;

        if (Platform.isAndroid) {
          locationSettings = AndroidSettings(
              distanceFilter: 0,
              forceLocationManager:
                  false, // Usar FusedLocationProviderClient por padrão (mais eficiente)
              intervalDuration: const Duration(seconds: 5),
              // Configuração importante para manter o serviço vivo em background
              foregroundNotificationConfig: const ForegroundNotificationConfig(
                notificationText:
                    "RotaSys continuará rastreando sua localização mesmo em segundo plano",
                notificationTitle: "RotaSys Ativo",
                enableWakeLock: true,
              ));
        } else if (Platform.isIOS) {
          locationSettings = AppleSettings(
            activityType: ActivityType.other,
            distanceFilter: 0,
            pauseLocationUpdatesAutomatically: false,
            // Indicador de que o app está usando localização em background
            showBackgroundLocationIndicator: true,
          );
        } else {
          locationSettings = const LocationSettings(
            distanceFilter: 0,
          );
        }

        // Obter posição atual com as configurações apropriadas
        final position = await Geolocator.getCurrentPosition(
          locationSettings: locationSettings,
        );

        debugPrint(
            '📍 Localização obtida com Geolocator: Lat=${position.latitude}, Lng=${position.longitude}');

        // Converter Position para LocationData para compatibilidade com código existente
        return LocationData.fromMap({
          'latitude': position.latitude,
          'longitude': position.longitude,
          'accuracy': position.accuracy,
          'altitude': position.altitude,
          'speed': position.speed,
          'speed_accuracy': position.speedAccuracy,
          'heading': position.heading,
          'time': position.timestamp?.millisecondsSinceEpoch ??
              DateTime.now().millisecondsSinceEpoch,
          'is_mocked': false,
        });
      } catch (directError) {
        debugPrint('⚠️ ERRO ao obter localização com Geolocator: $directError');

        // Tentar obter a última posição conhecida
        try {
          final lastPosition = await Geolocator.getLastKnownPosition();

          if (lastPosition != null) {
            debugPrint(
                '📍 Última localização conhecida: Lat=${lastPosition.latitude}, Lng=${lastPosition.longitude}');

            // Converter para LocationData
            return LocationData.fromMap({
              'latitude': lastPosition.latitude,
              'longitude': lastPosition.longitude,
              'accuracy': lastPosition.accuracy,
              'altitude': lastPosition.altitude,
              'speed': lastPosition.speed,
              'speed_accuracy': lastPosition.speedAccuracy,
              'heading': lastPosition.heading,
              'time': lastPosition.timestamp?.millisecondsSinceEpoch ??
                  DateTime.now().millisecondsSinceEpoch,
              'is_mocked': false,
            });
          }
        } catch (lastPosError) {
          debugPrint(
              '⚠️ Erro ao obter última localização conhecida: $lastPosError');
        }

        // Se não conseguiu com Geolocator, buscar do SharedPreferences
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
            'time': DateTime.now().millisecondsSinceEpoch,
            'is_mocked': false,
          });
        }

        debugPrint('⚠️ Nenhuma localização disponível');
        return null;
      }
    } catch (e) {
      debugPrint('❌ Erro ao obter localização com segurança: $e');
      return null;
    }
  }

  static Future<bool> _sendLocationToApi(PositionsStruct position) async {
    try {
      // Preparar payload
      final Map<String, dynamic> payload = {
        'cpf': position.cpf,
        'routeId': position.routeId,
        'latitude': position.latitude,
        'longitude': position.longitude,
        'isFinished': position.finish,
        'infoDt': dateTimeFormat(
          'yyyy-MM-dd HH:mm:ss',
          position.date,
          locale: 'pt_BR',
        ),
      };

      debugPrint('🔄 Enviando dados para API: $payload');

      // Fazer requisição HTTP
      final response = await http
          .post(
            Uri.parse(_apiUrl),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(payload),
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
        debugPrint(
            '❌ Permissões não concedidas, não foi possível iniciar o rastreamento');
        return false;
      }

      // Salvar parâmetros
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefKeyCpf, cpf);
      await prefs.setString(_prefKeyRouteId, routeId);
      await prefs.setBool(_prefKeyFinishViagem, finishViagem);
      await prefs.setBool(_prefKeyIsTrackingActive, true);

      // Salvar estatísticas iniciais
      await prefs.setInt(
          'bg_service_start_timestamp', DateTime.now().millisecondsSinceEpoch);
      await prefs.setInt('bg_service_successful_updates', 0);
      await prefs.setInt('bg_service_total_checks', 0);
      await prefs.setInt('bg_successful_api_sends', 0);

      // Iniciar o serviço
      final serviceStarted = await _service.startService();

      debugPrint('▶️ Serviço iniciado com sucesso: $serviceStarted');

      return serviceStarted;
    } catch (e) {
      debugPrint(
          '❌ Erro ao iniciar serviço de localização em segundo plano: $e');
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

  Future<void> checkAndRestartTracking() async {
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
      } else {
        debugPrint(
            '❗ Não foi possível reiniciar rastreamento: dados incompletos');
      }
    } else {
      debugPrint('ℹ️ Não há rastreamento ativo para reiniciar');
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
      await location.enableBackgroundMode(enable: true);
      debugPrint('🔵 Modo de segundo plano do location ativado');

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

      // Configurar timer para coletar a localização a cada 1 minuto
      // Nota: definimos como 1 minuto para testes, mas pode ser ajustado para 5 minutos em produção
      Timer.periodic(const Duration(minutes: 1), (timer) async {
        print("ENTROU AQUI A CADA 1 MINUTO NO SERVICE");
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
                    'Rastreando desde ${startTime.hour}:${startTime.minute.toString().padLeft(2, '0')} (${executionCount} verificações, ${successfulApiSends} enviadas)',
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
          service.invoke('keepAlive', {});
        });
      }
    } catch (e) {
      debugPrint('💥 Erro fatal no serviço de background: $e');
      service.stopSelf();
    }
  }
}
