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
import 'package:pigma/backend/schema/structs/positions_struct.dart';
import 'package:pigma/flutter_flow/flutter_flow_util.dart';

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

    if (await flutterLocalNotificationsPlugin
            .resolvePlatformSpecificImplementation<
                AndroidFlutterLocalNotificationsPlugin>() !=
        null) {
      await flutterLocalNotificationsPlugin
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>()
          ?.createNotificationChannel(const AndroidNotificationChannel(
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

  // Método para verificar e solicitar permissões
  Future<bool> checkAndRequestPermissions() async {
    final Location location = Location();

    try {
      // Verificar serviço
      bool serviceEnabled = await location.serviceEnabled();
      if (!serviceEnabled) {
        debugPrint('🔶 Serviço de localização não habilitado, solicitando...');
        serviceEnabled = await location.requestService();
        if (!serviceEnabled) {
          debugPrint('❌ Serviço de localização negado pelo usuário');
          return false;
        }
      }

      // Verificar permissão
      PermissionStatus permissionStatus = await location.hasPermission();
      if (permissionStatus == PermissionStatus.denied) {
        debugPrint('🔶 Permissão de localização não concedida, solicitando...');
        permissionStatus = await location.requestPermission();
        if (permissionStatus != PermissionStatus.granted) {
          debugPrint('❌ Permissão de localização negada pelo usuário');
          return false;
        }
      }

      // Verificar modo em segundo plano
      bool backgroundEnabled = await location.isBackgroundModeEnabled();
      if (!backgroundEnabled) {
        debugPrint('🔶 Modo em segundo plano não habilitado, habilitando...');
        backgroundEnabled = await location.enableBackgroundMode(enable: true);
        if (!backgroundEnabled) {
          debugPrint('❌ Não foi possível habilitar o modo em segundo plano');
          return false;
        }
      }

      debugPrint('✅ Todas as permissões concedidas com sucesso');
      return true;
    } catch (e) {
      debugPrint('❌ Erro ao verificar permissões: $e');
      return false;
    }
  }

  // Este método é chamado para iOS quando o app está em segundo plano
  @pragma('vm:entry-point')
  static Future<bool> _onIosBackground(ServiceInstance service) async {
    debugPrint('🔷 _onIosBackground chamado às ${DateTime.now()}');
    WidgetsFlutterBinding.ensureInitialized();
    DartPluginRegistrant.ensureInitialized();
    return true;
  }

  // Este método é o ponto de entrada do serviço em segundo plano
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
      final Location locationInstance = Location();
      await locationInstance.enableBackgroundMode(enable: true);
      debugPrint('🔵 Modo de segundo plano do location ativado');

      // Criar timer para verificar periodicidade de forma precisa
      int executionCount = 0;
      int successfulLocationUpdates = 0;
      final startTime = DateTime.now();

      // Salvar timestamp de início no SharedPreferences para rastreamento
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(
          'bg_service_start_timestamp', startTime.millisecondsSinceEpoch);

      // Configurar timer para coletar a localização a cada 1 minuto
      // Nota: definimos como 1 minuto para testes, mas pode ser ajustado para 5 minutos em produção
      Timer.periodic(const Duration(minutes: 1), (timer) async {
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
                    'Rastreando desde ${startTime.hour}:${startTime.minute.toString().padLeft(2, '0')} (${executionCount} verificações, ${successfulLocationUpdates} atualizações)',
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

          // Verificar permissões e status do serviço de localização
          bool locationPermissionOk = true;

          try {
            final serviceEnabled = await locationInstance.serviceEnabled();
            final permissionStatus = await locationInstance.hasPermission();

            debugPrint(
                '🟢 Status do serviço de localização: Habilitado=$serviceEnabled, Permissão=$permissionStatus');

            if (!serviceEnabled ||
                permissionStatus != PermissionStatus.granted) {
              locationPermissionOk = false;
            }
          } catch (e) {
            debugPrint('❌ Erro ao verificar status da localização: $e');
            locationPermissionOk = false;
          }

          if (!locationPermissionOk) {
            debugPrint(
                '❗ Serviço de localização ou permissões não disponíveis');
            // Tentar reativar o serviço de localização
            try {
              await locationInstance.enableBackgroundMode(enable: true);
            } catch (e) {
              debugPrint('❌ Não foi possível reativar o serviço: $e');
            }
            return;
          }

          // Obter localização atual
          try {
            debugPrint('🟢 Obtendo localização atual...');
            final locationData = await locationInstance.getLocation();

            if (locationData.latitude == null ||
                locationData.longitude == null) {
              debugPrint('❗ Localização obtida com valores nulos');
              return;
            }

            debugPrint(
                '📍 Localização obtida: Latitude=${locationData.latitude}, Longitude=${locationData.longitude}');
            successfulLocationUpdates++;

            // Salvar estatísticas de sucesso
            await prefs.setInt(
                'bg_service_successful_updates', successfulLocationUpdates);
            await prefs.setInt('bg_service_total_checks', executionCount);

            // Criar estrutura de posição - CORRIGIDO
            // Primeiro criar as datas para evitar o erro de expressão void
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

            // Salvar a posição para sincronização posterior
            await _savePositionForSync(position);

            // Enviar dados para o aplicativo principal - CORRIGIDO
            // Criar mapa separadamente antes de invocar
            final Map<String, dynamic> locationUpdateData = {
              'latitude': locationData.latitude,
              'longitude': locationData.longitude,
              'timestamp': DateTime.now().millisecondsSinceEpoch,
              'routeId': routeId,
              'cpf': cpf,
            };

            // Agora, use o mapa na função invoke
            service.invoke('update_location', locationUpdateData);

            // Salvar última localização para recuperação se o serviço for reiniciado
            await prefs.setDouble('bg_last_latitude', locationData.latitude!);
            await prefs.setDouble('bg_last_longitude', locationData.longitude!);
          } catch (e) {
            debugPrint('❌ Erro ao obter localização: $e');

            // Tentar reativar o serviço de localização em caso de erro
            try {
              await locationInstance.enableBackgroundMode(enable: true);
            } catch (innerError) {
              debugPrint(
                  '❌ Erro ao reativar modo em segundo plano: $innerError');
            }
          }
        } catch (e) {
          debugPrint('❌ Erro no timer principal: $e');
        }
      });

      // Se estivermos no Android, garantir que o serviço não seja facilmente encerrado
      if (Platform.isAndroid) {
        debugPrint(
            '🔵 Configurando serviço no Android para evitar que seja encerrado');

        // Registrar receiver para reiniciar o serviço se for encerrado - CORRIGIDO
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

  // Salvar posição para sincronização posterior
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

  // Iniciar o serviço de rastreamento
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

  // Parar o serviço de rastreamento
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

  // Verificar se o serviço deve ser reiniciado
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

  // Verificar se o serviço está em execução
  Future<bool> isRunning() async {
    final running = await _service.isRunning();
    debugPrint('ℹ️ Serviço está rodando: $running');
    return running;
  }

  // Obter estatísticas do serviço
  Future<Map<String, dynamic>> getServiceStatistics() async {
    try {
      final prefs = await SharedPreferences.getInstance();

      final startTimestamp = prefs.getInt('bg_service_start_timestamp') ?? 0;
      final lastUpdateTimestamp =
          prefs.getInt(_prefKeyLastUpdateTimestamp) ?? 0;
      final totalChecks = prefs.getInt('bg_service_total_checks') ?? 0;
      final successfulUpdates =
          prefs.getInt('bg_service_successful_updates') ?? 0;
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
        'successRate': totalChecks > 0
            ? (successfulUpdates / totalChecks * 100).toStringAsFixed(1) + '%'
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
}
