import 'dart:io';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart' as permission;
import 'package:geolocator/geolocator.dart';
import 'package:app_settings/app_settings.dart';

class LocationPermissionService {
  /// Verifica se as permissões de localização estão corretamente configuradas
  static Future<bool> hasCorrectLocationPermissions() async {
    try {
      if (Platform.isAndroid) {
        // Verificar se o serviço de localização está habilitado
        bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
        if (!serviceEnabled) {
          debugPrint('❌ Serviço de localização não habilitado');
          return false;
        }

        // Verificar permissões usando permission_handler para maior precisão
        var locationWhenInUse =
            await permission.Permission.locationWhenInUse.status;
        var locationAlways = await permission.Permission.locationAlways.status;

        debugPrint('🔍 Permissão durante uso: $locationWhenInUse');
        debugPrint('🔍 Permissão sempre ativa: $locationAlways');

        // Para funcionamento em background, precisamos da permissão "sempre ativa"
        bool hasBackgroundPermission =
            locationAlways == permission.PermissionStatus.granted;

        if (!hasBackgroundPermission) {
          debugPrint('❌ Permissão de localização em background não concedida');
          return false;
        }

        debugPrint('✅ Permissões de localização estão corretas');
        return true;
      } else {
        // iOS - verificar permissões
        var locationAlways = await permission.Permission.locationAlways.status;
        return locationAlways == permission.PermissionStatus.granted;
      }
    } catch (e) {
      debugPrint('❌ Erro ao verificar permissões de localização: $e');
      return false;
    }
  }

  /// Solicita as permissões necessárias com fallback para configurações manuais
  static Future<bool> requestLocationPermissions(BuildContext context) async {
    try {
      debugPrint('🔄 Solicitando permissões de localização...');

      if (Platform.isAndroid) {
        // Primeiro, solicitar permissão durante o uso
        var locationWhenInUse =
            await permission.Permission.locationWhenInUse.request();

        if (locationWhenInUse != permission.PermissionStatus.granted) {
          debugPrint('❌ Permissão durante uso negada');
          await _showLocationPermissionDialog(context, false);
          return false;
        }

        // Aguardar um pouco antes de solicitar a permissão "sempre ativa"
        await Future.delayed(const Duration(seconds: 1));

        // Solicitar permissão "sempre ativa" (background)
        var locationAlways =
            await permission.Permission.locationAlways.request();

        if (locationAlways != permission.PermissionStatus.granted) {
          debugPrint('❌ Permissão sempre ativa negada ou não solicitada');
          // Mostrar dialog explicativo
          await _showLocationPermissionDialog(context, true);
          return false;
        }

        debugPrint('✅ Todas as permissões de localização concedidas');
        return true;
      } else {
        // iOS
        var locationAlways =
            await permission.Permission.locationAlways.request();
        if (locationAlways != permission.PermissionStatus.granted) {
          await _showLocationPermissionDialog(context, true);
          return false;
        }
        return true;
      }
    } catch (e) {
      debugPrint('❌ Erro ao solicitar permissões: $e');
      await _showLocationPermissionDialog(context, true);
      return false;
    }
  }

  /// Verifica periodicamente as permissões (similar ao battery check)
  static Future<void> periodicLocationPermissionCheck(
      BuildContext context) async {
    try {
      final hasCorrectPermissions = await hasCorrectLocationPermissions();

      if (!hasCorrectPermissions) {
        debugPrint(
            '⚠️ Verificação periódica: Permissões de localização inadequadas');

        // Mostrar aviso discreto
        if (context.mounted) {
          _showLocationPermissionWarning(context);
        }
      }
    } catch (e) {
      debugPrint('⚠️ Erro na verificação periódica de localização: $e');
    }
  }

  /// Dialog explicativo para configuração manual
  static Future<void> _showLocationPermissionDialog(
      BuildContext context, bool needsAlwaysPermission) async {
    if (!context.mounted) return;

    return showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Row(
            children: [
              Icon(Icons.location_on, color: Colors.orange),
              SizedBox(width: 8),
              Text('Permissão de Localização'),
            ],
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  needsAlwaysPermission
                      ? 'Para que o rastreamento funcione em segundo plano, é necessário permitir o acesso à localização "o tempo todo".'
                      : 'É necessário permitir o acesso à localização para o funcionamento do aplicativo.',
                  style: const TextStyle(fontSize: 16),
                ),
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.blue.shade50,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.blue.shade200),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        '📱 Como configurar:',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        Platform.isAndroid
                            ? '1. Toque em "Abrir Configurações"\n'
                                '2. Encontre "RotaSys" na lista\n'
                                '3. Toque em "Permissões"\n'
                                '4. Toque em "Localização"\n'
                                '5. Selecione "Permitir o tempo todo"'
                            : '1. Toque em "Abrir Configurações"\n'
                                '2. Encontre "RotaSys"\n'
                                '3. Toque em "Localização"\n'
                                '4. Selecione "Sempre"',
                        style: const TextStyle(fontSize: 13),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                const Text(
                  '⚠️ Sem essa configuração, o rastreamento pode parar quando o aplicativo estiver em segundo plano.',
                  style: TextStyle(
                    fontSize: 14,
                    color: Colors.red,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Entendi'),
            ),
            ElevatedButton(
              onPressed: () async {
                Navigator.of(context).pop();
                await AppSettings.openAppSettings(
                    type: AppSettingsType.settings);
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF4646B4),
                foregroundColor: Colors.white,
              ),
              child: const Text('Abrir Configurações'),
            ),
          ],
        );
      },
    );
  }

  /// Aviso discreto via SnackBar
  static void _showLocationPermissionWarning(BuildContext context) {
    if (!context.mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Row(
          children: [
            Icon(Icons.location_off, color: Colors.white, size: 20),
            SizedBox(width: 8),
            Expanded(
              child: Text(
                'Configure a localização "o tempo todo" para rastreamento em segundo plano',
                style: TextStyle(fontSize: 14),
              ),
            ),
          ],
        ),
        action: SnackBarAction(
          label: 'Configurar',
          textColor: Colors.white,
          onPressed: () async {
            await requestLocationPermissions(context);
          },
        ),
        duration: const Duration(seconds: 8),
        backgroundColor: Colors.orange.shade700,
      ),
    );
  }

  /// Obter detalhes das permissões para debug
  static Future<Map<String, dynamic>> getLocationPermissionDetails() async {
    try {
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      final whenInUse = await permission.Permission.locationWhenInUse.status;
      final always = await permission.Permission.locationAlways.status;

      return {
        'serviceEnabled': serviceEnabled,
        'whenInUsePermission': whenInUse.toString(),
        'alwaysPermission': always.toString(),
        'hasCorrectPermissions': await hasCorrectLocationPermissions(),
        'deviceInfo': Platform.isAndroid ? 'Android' : 'iOS',
      };
    } catch (e) {
      return {
        'error': e.toString(),
      };
    }
  }
}
