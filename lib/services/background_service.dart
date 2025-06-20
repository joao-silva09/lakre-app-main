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
import 'package:pigma/services/battery_optimization_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import 'package:pigma/backend/schema/structs/positions_struct.dart';
import 'package:pigma/flutter_flow/flutter_flow_util.dart';
import 'package:geolocator/geolocator.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:permission_handler/permission_handler.dart' as perm;

/// Serviço de localização em background usando apenas Geolocator
///
/// Esta classe gerencia o rastreamento de localização tanto em foreground
/// quanto em background, eliminando a duplicação de bibliotecas.
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

  /// Verifica e solicita todas as permissões necessárias
  static Future<bool> checkAndRequestLocationPermissions() async {
    debugPrint('🔍 Verificando permissões de localização');

    try {
      // Verificar se o serviço de localização está habilitado
      bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        debugPrint('❌ Serviço de localização não está habilitado');
        return false;
      }

      // Verificar permissão atual
      LocationPermission permission = await Geolocator.checkPermission();

      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied) {
          debugPrint('❌ Permissão de localização negada');
          return false;
        }
      }

      if (permission == LocationPermission.deniedForever) {
        debugPrint('❌ Permissão de localização negada permanentemente');
        return false;
      }

      // Para iOS, verificar permissões específicas de background
      if (Platform.isIOS) {
        var locationAlways = await perm.Permission.locationAlways.status;
        if (locationAlways != perm.PermissionStatus.granted) {
          locationAlways = await perm.Permission.locationAlways.request();
          if (locationAlways != perm.PermissionStatus.granted) {
            debugPrint(
                '❌ Permissão de localização em segundo plano não concedida no iOS');
            return false;
          }
        }

        // Verificar notificações para iOS
        var notification = await perm.Permission.notification.status;
        if (notification != perm.PermissionStatus.granted) {
          notification = await perm.Permission.notification.request();
        }

        debugPrint('✅ Permissões de localização iOS configuradas');
      }

      debugPrint('✅ Todas as permissões de localização concedidas');
      return true;
    } catch (e) {
      debugPrint('❌ Erro ao verificar permissões: $e');
      return false;
    }
  }

  /// Obtém a localização atual usando apenas Geolocator
  static Future<Position?> getCurrentLocation() async {
    try {
      late LocationSettings locationSettings;

      if (Platform.isIOS) {
        locationSettings = AppleSettings(
          accuracy: LocationAccuracy.high,
          activityType: ActivityType.automotiveNavigation,
          distanceFilter: 0,
          pauseLocationUpdatesAutomatically: false,
          showBackgroundLocationIndicator: true,
          allowBackgroundLocationUpdates: true,
        );
      } else {
        locationSettings = AndroidSettings(
          accuracy: LocationAccuracy.high,
          distanceFilter: 0,
          forceLocationManager: false,
          intervalDuration: const Duration(seconds: 5),
          foregroundNotificationConfig: const ForegroundNotificationConfig(
            notificationText: "RotaSys continuará rastreando sua localização",
            notificationTitle: "RotaSys Ativo",
            enableWakeLock: true,
          ),
        );
      }

      final position = await Geolocator.getCurrentPosition(
        locationSettings: locationSettings,
      );

      debugPrint(
          '📍 Localização obtida: Lat=${position.latitude}, Lng=${position.longitude}');

      // Salvar última localização conhecida
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble('last_latitude', position.latitude);
      await prefs.setDouble('last_longitude', position.longitude);
      await prefs.setInt(
          'last_location_timestamp', DateTime.now().millisecondsSinceEpoch);

      return position;
    } catch (e) {
      debugPrint('⚠️ Erro ao obter localização atual: $e');

      // Tentar obter última posição conhecida
      try {
        final lastPosition = await Geolocator.getLastKnownPosition();
        if (lastPosition != null) {
          debugPrint(
              '📍 Usando última localização conhecida: Lat=${lastPosition.latitude}, Lng=${lastPosition.longitude}');
          return lastPosition;
        }
      } catch (lastError) {
        debugPrint('⚠️ Erro ao obter última localização: $lastError');
      }

      return null;
    }
  }

  /// Verifica e solicita permissões de bateria
  Future<bool> checkAndRequestBatteryPermissions(BuildContext context) async {
    debugPrint('🔋 Verificando permissões de otimização de bateria');

    final batteryPermissionGranted =
        await BatteryOptimizationService.checkAndRequestBatteryPermissions(
            context);

    if (!batteryPermissionGranted) {
      debugPrint('❌ Permissões de bateria não concedidas');
      return false;
    }

    debugPrint('✅ Permissões de bateria configuradas corretamente');
    return true;
  }

  /// Inicializa o serviço de background
  Future<void> initialize() async {
    debugPrint('🔷 Inicializando serviço de localização em segundo plano');

    final flutterLocalNotificationsPlugin = FlutterLocalNotificationsPlugin();

    if (Platform.isAndroid) {
      final androidImplementation =
          flutterLocalNotificationsPlugin.resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>();
      if (androidImplementation != null) {
        await androidImplementation.createNotificationChannel(
          const AndroidNotificationChannel(
            _notificationChannelId,
            _notificationChannelName,
            description: _notificationChannelDescription,
            importance: Importance.low,
          ),
        );
      }
    }

    await _service.configure(
      androidConfiguration: AndroidConfiguration(
        onStart: onStart,
        autoStart: false,
        isForegroundMode: true,
        notificationChannelId: _notificationChannelId,
        initialNotificationTitle: 'RotaSys Ativo',
        initialNotificationContent: 'Rastreando sua rota...',
        foregroundServiceNotificationId: 888,
      ),
      iosConfiguration: IosConfiguration(
        autoStart: false,
        onForeground: onStart,
        onBackground: onIosBackground,
      ),
    );
  }

  /// Inicia o rastreamento de localização
  Future<bool> startLocationUpdates({
    required String cpf,
    required String routeId,
    bool finishViagem = false,
    BuildContext? context,
  }) async {
    debugPrint('▶️ Iniciando rastreamento: CPF=$cpf, RouteId=$routeId');

    try {
      // Verificar permissões
      final permissionsGranted = await checkAndRequestLocationPermissions();
      if (!permissionsGranted) {
        debugPrint('❌ Permissões de localização não concedidas');
        return false;
      }

      // Verificar permissões de bateria se contexto fornecido
      if (context != null) {
        final batteryPermissionGranted =
            await checkAndRequestBatteryPermissions(context);
        if (!batteryPermissionGranted) {
          debugPrint(
              '⚠️ Permissões de bateria não concedidas - serviço pode ser interrompido');
        }
      }

      // Salvar parâmetros
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefKeyCpf, cpf);
      await prefs.setString(_prefKeyRouteId, routeId);
      await prefs.setBool(_prefKeyFinishViagem, finishViagem);
      await prefs.setBool(_prefKeyIsTrackingActive, true);

      // Iniciar o serviço
      final serviceStarted = await _service.startService();
      if (serviceStarted) {
        debugPrint('✅ Serviço de background iniciado com sucesso');
        return true;
      } else {
        debugPrint('❌ Falha ao iniciar serviço de background');
        return false;
      }
    } catch (e) {
      debugPrint('❌ Erro ao iniciar rastreamento: $e');
      return false;
    }
  }

  /// Para o rastreamento de localização
  Future<void> stopLocationUpdates() async {
    debugPrint('⏹️ Parando rastreamento de localização');

    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefKeyIsTrackingActive, false);

    // Enviar comando para parar
    _service.invoke('stop_tracking');

    // Aguardar um pouco e parar o serviço
    await Future.delayed(const Duration(seconds: 2));
    await _service.invoke('stop');
  }

  /// Verifica se o rastreamento está ativo
  Future<bool> isTrackingActive() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_prefKeyIsTrackingActive) ?? false;
  }

  /// Entry point do serviço em background
  @pragma('vm:entry-point')
  static Future<void> onStart(ServiceInstance service) async {
    debugPrint('🔷 Serviço de background iniciado');

    DartPluginRegistrant.ensureInitialized();

    bool isServiceRunning = true;
    int executionCount = 0;
    int successfulLocationUpdates = 0;
    int successfulApiSends = 0;

    // Configurar handlers para comandos
    service.on('stop_tracking').listen((event) {
      debugPrint('🔴 Comando para parar rastreamento recebido');
      isServiceRunning = false;
    });

    service.on('stop').listen((event) {
      debugPrint('🔴 Comando para parar serviço recebido');
      isServiceRunning = false;
      service.stopSelf();
    });

    // Timer principal - a cada 5 minutos conforme especificação
    Timer.periodic(const Duration(minutes: 5), (timer) async {
      if (!isServiceRunning) {
        timer.cancel();
        service.stopSelf();
        return;
      }

      executionCount++;
      debugPrint('🔄 Execução #$executionCount do serviço background');

      try {
        final prefs = await SharedPreferences.getInstance();
        final isActive = prefs.getBool(_prefKeyIsTrackingActive) ?? false;

        if (!isActive) {
          debugPrint('🔴 Rastreamento inativo, parando serviço');
          isServiceRunning = false;
          service.stopSelf();
          return;
        }

        final cpf = prefs.getString(_prefKeyCpf) ?? '';
        final routeId = prefs.getString(_prefKeyRouteId) ?? '';
        final finishViagem = prefs.getBool(_prefKeyFinishViagem) ?? false;

        if (cpf.isEmpty || routeId.isEmpty) {
          debugPrint('❗ CPF ou RouteId vazios, pulando atualização');
          return;
        }

        // Obter localização atual
        final position = await getCurrentLocation();
        if (position == null) {
          debugPrint('❗ Não foi possível obter localização');
          return;
        }

        successfulLocationUpdates++;
        debugPrint(
            '📍 Localização #$successfulLocationUpdates: ${position.latitude}, ${position.longitude}');

        // Criar estrutura de posição
        final DateTime dataHora = DateTime.now();
        final DateTime dataHoraAjustada = dataHora
            .subtract(dataHora.timeZoneOffset)
            .subtract(const Duration(hours: 3));

        final positionStruct = PositionsStruct(
          cpf: cpf,
          routeId: int.tryParse(routeId),
          latitude: position.latitude,
          longitude: position.longitude,
          date: dataHoraAjustada,
          finish: false,
          finishViagem: finishViagem,
        );

        // Tentar enviar para API
        final sentSuccessfully = await _sendLocationToApi(positionStruct);

        if (sentSuccessfully) {
          successfulApiSends++;
          debugPrint('✅ Localização enviada para API (#$successfulApiSends)');
        } else {
          await _savePositionForSync(positionStruct);
          debugPrint('⚠️ Falha no envio, salvo para sincronização posterior');
        }

        // Tentar sincronizar posições pendentes
        await _trySyncPendingPositions();

        // Atualizar estatísticas
        await prefs.setInt(
            'bg_service_successful_updates', successfulLocationUpdates);
        await prefs.setInt('bg_service_total_checks', executionCount);
        await prefs.setInt('bg_successful_api_sends', successfulApiSends);
        await prefs.setInt(
            _prefKeyLastUpdateTimestamp, DateTime.now().millisecondsSinceEpoch);

        // Enviar atualização para o app principal (se aberto)
        service.invoke('update_location', {
          'latitude': position.latitude,
          'longitude': position.longitude,
          'timestamp': DateTime.now().millisecondsSinceEpoch,
          'routeId': routeId,
          'cpf': cpf,
        });
      } catch (e) {
        debugPrint('❌ Erro no timer do serviço: $e');
      }
    });

    // Para iOS, manter serviço ativo com pings periódicos
    if (Platform.isIOS) {
      Timer.periodic(const Duration(minutes: 10), (timer) {
        if (!isServiceRunning) {
          timer.cancel();
          return;
        }
        debugPrint('🔄 Ping de manutenção iOS');
        service.invoke(
            'keepAlive', {'timestamp': DateTime.now().millisecondsSinceEpoch});
      });
    }
  }

  /// Entry point específico para iOS background
  @pragma('vm:entry-point')
  static Future<bool> onIosBackground(ServiceInstance service) async {
    debugPrint('🔷 iOS background callback executado');

    WidgetsFlutterBinding.ensureInitialized();
    DartPluginRegistrant.ensureInitialized();

    final prefs = await SharedPreferences.getInstance();
    final isActive = prefs.getBool(_prefKeyIsTrackingActive) ?? false;

    if (!isActive) {
      return true;
    }

    try {
      final cpf = prefs.getString(_prefKeyCpf) ?? '';
      final routeId = prefs.getString(_prefKeyRouteId) ?? '';

      if (cpf.isNotEmpty && routeId.isNotEmpty) {
        final position = await getCurrentLocation();

        if (position != null) {
          final DateTime dataHora = DateTime.now();
          final DateTime dataHoraAjustada = dataHora
              .subtract(dataHora.timeZoneOffset)
              .subtract(const Duration(hours: 3));

          final finishViagem = prefs.getBool(_prefKeyFinishViagem) ?? false;

          final positionStruct = PositionsStruct(
            cpf: cpf,
            routeId: int.tryParse(routeId),
            latitude: position.latitude,
            longitude: position.longitude,
            date: dataHoraAjustada,
            finish: false,
            finishViagem: finishViagem,
          );

          final sentSuccessfully = await _sendLocationToApi(positionStruct);

          if (!sentSuccessfully) {
            await _savePositionForSync(positionStruct);
          }

          debugPrint('📍 iOS background: localização processada');
        }
      }
    } catch (e) {
      debugPrint('❌ Erro no iOS background: $e');
    }

    return true;
  }

  /// Envia localização para a API
  static Future<bool> _sendLocationToApi(PositionsStruct position) async {
    try {
      await initializeDateFormatting('pt_BR', null);

      const apiUrl =
          'https://lakre.pigmadesenvolvimentos.com.br:10529/apis/PostPosition';

      Map<String, String> headers = {
        'Content-Type': 'application/x-www-form-urlencoded',
        'User-Agent': 'com.pigmadesenvolvimentos.lakretracking',
        'Authorization': 'JlEIJjmoLMKtkpxDqOzWAGpkTePDQonu',
      };

      final formattedDate = dateTimeFormat(
        'yyyy-MM-dd HH:mm:ss',
        position.date,
        locale: 'pt_BR',
      );

      final Map<String, String> params = {
        'cpf': position.cpf ?? '',
        'routeId': (position.routeId ?? 0).toString(),
        'latitude': (position.latitude ?? 0).toString(),
        'longitude': (position.longitude ?? 0).toString(),
        'isFinished': (position.finish ?? false).toString(),
        'finishViagem': (position.finishViagem ?? false).toString(),
        'date': formattedDate,
      };

      final response = await http
          .post(
            Uri.parse(apiUrl),
            headers: headers,
            body: params,
          )
          .timeout(const Duration(seconds: 30));

      if (response.statusCode == 200) {
        debugPrint('✅ Localização enviada com sucesso para API');
        return true;
      } else {
        debugPrint('⚠️ Erro no envio para API: Status ${response.statusCode}');
        return false;
      }
    } catch (e) {
      debugPrint('❌ Erro ao enviar para API: $e');
      return false;
    }
  }

  /// Salva posição para sincronização posterior
  static Future<void> _savePositionForSync(PositionsStruct position) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      List<String> pendingPositions =
          prefs.getStringList('pending_positions') ?? [];

      final positionJson = jsonEncode({
        'cpf': position.cpf,
        'routeId': position.routeId,
        'latitude': position.latitude,
        'longitude': position.longitude,
        'date': position.date?.millisecondsSinceEpoch,
        'finish': position.finish,
        'finishViagem': position.finishViagem,
      });

      pendingPositions.add(positionJson);

      // Manter apenas os últimos 50 para evitar overflow
      if (pendingPositions.length > 50) {
        pendingPositions =
            pendingPositions.sublist(pendingPositions.length - 50);
      }

      await prefs.setStringList('pending_positions', pendingPositions);
      debugPrint(
          '💾 Posição salva para sincronização posterior (${pendingPositions.length} pendentes)');
    } catch (e) {
      debugPrint('❌ Erro ao salvar posição para sync: $e');
    }
  }

  /// Tenta sincronizar posições pendentes
  static Future<void> _trySyncPendingPositions() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      List<String> pendingPositions =
          prefs.getStringList('pending_positions') ?? [];

      if (pendingPositions.isEmpty) {
        return;
      }

      debugPrint(
          '🔄 Tentando sincronizar ${pendingPositions.length} posições pendentes');

      List<String> stillPending = [];
      int syncedCount = 0;

      for (String positionJson in pendingPositions) {
        try {
          final Map<String, dynamic> positionData = jsonDecode(positionJson);

          final position = PositionsStruct(
            cpf: positionData['cpf'],
            routeId: positionData['routeId'],
            latitude: positionData['latitude'],
            longitude: positionData['longitude'],
            date: positionData['date'] != null
                ? DateTime.fromMillisecondsSinceEpoch(positionData['date'])
                : DateTime.now(),
            finish: positionData['finish'] ?? false,
            finishViagem: positionData['finishViagem'] ?? false,
          );

          final sent = await _sendLocationToApi(position);

          if (sent) {
            syncedCount++;
          } else {
            stillPending.add(positionJson);
          }
        } catch (e) {
          debugPrint('⚠️ Erro ao processar posição pendente: $e');
          stillPending.add(positionJson);
        }
      }

      await prefs.setStringList('pending_positions', stillPending);

      if (syncedCount > 0) {
        debugPrint(
            '✅ Sincronizadas $syncedCount posições. ${stillPending.length} ainda pendentes');
      }
    } catch (e) {
      debugPrint('❌ Erro na sincronização de posições pendentes: $e');
    }
  }
}
