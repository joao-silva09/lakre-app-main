// lib/services/battery_optimization_service.dart

import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

class BatteryOptimizationService {
  static const MethodChannel _channel = MethodChannel('battery_optimization');

  /// Verifica se o aplicativo está na lista de otimização de bateria (Android)
  static Future<bool> isBatteryOptimizationDisabled() async {
    if (!Platform.isAndroid) return true;

    try {
      final bool result =
          await _channel.invokeMethod('isBatteryOptimizationDisabled');
      debugPrint(
          '🔋 Status otimização de bateria: ${result ? "DESABILITADA" : "ATIVA"}');
      return result;
    } on PlatformException catch (e) {
      debugPrint('❌ Erro ao verificar otimização de bateria: ${e.message}');
      return false;
    } catch (e) {
      debugPrint('❌ Erro inesperado ao verificar bateria: $e');
      return false;
    }
  }

  /// Abre as configurações de otimização de bateria para o aplicativo
  static Future<bool> requestDisableBatteryOptimization() async {
    if (!Platform.isAndroid) return true;

    try {
      debugPrint('🔋 Solicitando desabilitação da otimização de bateria...');
      final bool result =
          await _channel.invokeMethod('requestDisableBatteryOptimization');
      debugPrint('🔋 Resultado da solicitação: $result');
      return result;
    } on PlatformException catch (e) {
      debugPrint(
          '❌ Erro ao solicitar desabilitação da otimização de bateria: ${e.message}');
      return false;
    } catch (e) {
      debugPrint('❌ Erro inesperado ao solicitar configuração: $e');
      return false;
    }
  }

  /// Verifica se o aplicativo pode ignorar otimizações de bateria
  static Future<bool> canIgnoreBatteryOptimizations() async {
    if (!Platform.isAndroid) return true;

    try {
      final bool result =
          await _channel.invokeMethod('canIgnoreBatteryOptimizations');
      debugPrint('🔋 Pode ignorar otimizações: $result');
      return result;
    } on PlatformException catch (e) {
      debugPrint(
          '❌ Erro ao verificar permissão de ignorar otimização: ${e.message}');
      return false;
    } catch (e) {
      debugPrint('❌ Erro inesperado ao verificar permissão: $e');
      return false;
    }
  }

  /// Abre as configurações de aplicativos do sistema
  static Future<void> openAppSettings() async {
    try {
      await openAppSettings();
    } catch (e) {
      debugPrint('❌ Erro ao abrir configurações do app: $e');
    }
  }

  /// Verifica o status da bateria e solicita permissão se necessário
  static Future<bool> checkAndRequestBatteryPermissions(
      BuildContext context) async {
    if (!Platform.isAndroid) return true;

    try {
      debugPrint('🔋 Iniciando verificação de permissões de bateria...');

      // Verificar se já está desabilitado
      final isDisabled = await isBatteryOptimizationDisabled();
      if (isDisabled) {
        debugPrint('✅ Otimização de bateria já está desabilitada');
        return true;
      }

      // Verificar se pode ignorar otimizações
      final canIgnore = await canIgnoreBatteryOptimizations();
      debugPrint('🔋 Pode solicitar configuração: $canIgnore');

      if (!canIgnore) {
        debugPrint('❌ Aplicativo não pode ignorar otimizações de bateria');

        // Mostrar instruções manuais se não pode solicitar automaticamente
        if (context.mounted) {
          _showManualInstructionsDialog(context);
        }
        return false;
      }

      // Mostrar dialog explicativo
      final shouldRequest = await _showBatteryOptimizationDialog(context);
      if (!shouldRequest) {
        debugPrint('ℹ️ Usuário escolheu não configurar a bateria agora');
        return false;
      }

      // Solicitar desabilitação
      debugPrint('🔋 Abrindo configurações de bateria...');
      final result = await requestDisableBatteryOptimization();

      // Aguardar um pouco e verificar novamente
      await Future.delayed(const Duration(seconds: 2));
      final finalCheck = await isBatteryOptimizationDisabled();

      if (finalCheck) {
        debugPrint('✅ Otimização de bateria desabilitada com sucesso');
        if (context.mounted) {
          _showSuccessDialog(context);
        }
        return true;
      } else {
        debugPrint(
            '⚠️ Usuário não desabilitou a otimização de bateria ou configuração falhou');
        if (context.mounted) {
          _showPartialSuccessDialog(context);
        }
        return false;
      }
    } catch (e) {
      debugPrint('❌ Erro durante verificação de permissões de bateria: $e');
      if (context.mounted) {
        _showErrorDialog(context, e.toString());
      }
      return false;
    }
  }

  /// Dialog explicativo sobre otimização de bateria
  static Future<bool> _showBatteryOptimizationDialog(
      BuildContext context) async {
    return await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (BuildContext context) {
            return AlertDialog(
              title: const Row(
                children: [
                  Icon(Icons.battery_alert, color: Colors.orange),
                  SizedBox(width: 8),
                  Text('Otimização de Bateria'),
                ],
              ),
              content: const SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Para garantir que o rastreamento funcione corretamente em segundo plano, '
                      'é necessário desabilitar a otimização de bateria para o RotaSys.',
                      style: TextStyle(fontSize: 16),
                    ),
                    SizedBox(height: 16),
                    Text(
                      'Ao tocar em "Configurar", você será direcionado para as configurações '
                      'onde deverá selecionar "Permitir" ou selecionar "Não otimizar" na tela de uso de bateria do aplicativo.',
                      style:
                          TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
                    ),
                    SizedBox(height: 16),
                    Text(
                      '⚠️ Sem essa permissão, o aplicativo pode parar de funcionar '
                      'quando estiver em segundo plano.',
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
                  onPressed: () => Navigator.of(context).pop(false),
                  child: const Text('Agora Não'),
                ),
                ElevatedButton(
                  onPressed: () => Navigator.of(context).pop(true),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF4646B4),
                    foregroundColor: Colors.white,
                  ),
                  child: const Text('Configurar'),
                ),
              ],
            );
          },
        ) ??
        false;
  }

  /// Dialog de sucesso
  static void _showSuccessDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Row(
            children: [
              SizedBox(width: 8),
              Text('Configuração Concluída'),
            ],
          ),
          content: const Text(
            'Perfeito! A otimização de bateria foi desabilitada. '
            'Agora o RotaSys funcionará corretamente em segundo plano.',
          ),
          actions: [
            ElevatedButton(
              onPressed: () => Navigator.of(context).pop(),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.green,
                foregroundColor: Colors.white,
              ),
              child: const Text('OK'),
            ),
          ],
        );
      },
    );
  }

  /// Dialog de sucesso parcial (configurações foram abertas)
  static void _showPartialSuccessDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Row(
            children: [
              Icon(Icons.info, color: Colors.blue),
              SizedBox(width: 8),
              Text('Configuração Pendente'),
            ],
          ),
          content: const Text(
            'As configurações foram abertas. Para garantir o melhor funcionamento:\n\n'
            '1. Encontre o RotaSys na lista\n'
            '2. Selecione "Não restrito"\n'
            '3. Volte para o aplicativo\n\n'
            'Você pode verificar o status atual tocando no ícone de bateria no menu.',
          ),
          actions: [
            ElevatedButton(
              onPressed: () => Navigator.of(context).pop(),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.blue,
                foregroundColor: Colors.white,
              ),
              child: const Text('Entendi'),
            ),
          ],
        );
      },
    );
  }

  /// Dialog de instruções manuais
  static void _showManualInstructionsDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Row(
            children: [
              Icon(Icons.settings, color: Colors.orange),
              SizedBox(width: 8),
              Text('Configuração Manual'),
            ],
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Para melhor funcionamento do aplicativo em segundo plano, '
                  'configure manualmente a otimização de bateria:',
                  style: TextStyle(fontSize: 16),
                ),
                const SizedBox(height: 16),
                Text(
                  getManufacturerSpecificInstructions(),
                  style: const TextStyle(fontSize: 14),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Agora Não'),
            ),
            ElevatedButton(
              onPressed: () {
                Navigator.of(context).pop();
                openAppSettings();
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

  /// Dialog de erro
  static void _showErrorDialog(BuildContext context, String error) {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Row(
            children: [
              Icon(Icons.error, color: Colors.red),
              SizedBox(width: 8),
              Text('Erro'),
            ],
          ),
          content: Text(
            'Ocorreu um erro ao verificar as configurações de bateria:\n\n$error\n\n'
            'Você pode configurar manualmente em:\n'
            'Configurações > Aplicativos > RotaSys > Bateria',
          ),
          actions: [
            ElevatedButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('OK'),
            ),
          ],
        );
      },
    );
  }

  /// Verifica periodicamente o status da bateria
  static Future<void> periodicBatteryCheck(BuildContext context) async {
    if (!Platform.isAndroid) return;

    final isDisabled = await isBatteryOptimizationDisabled();
    if (!isDisabled) {
      debugPrint('⚠️ Otimização de bateria ainda está ativa');

      // Mostrar notificação discreta
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text(
              'Para melhor funcionamento, desabilite a otimização de bateria do RotaSys',
            ),
            action: SnackBarAction(
              label: 'Configurar',
              onPressed: () => checkAndRequestBatteryPermissions(context),
            ),
            duration: const Duration(seconds: 5),
          ),
        );
      }
    }
  }

  /// Obtém instruções específicas do fabricante
  static String getManufacturerSpecificInstructions() {
    return '📱 Passo a passo:\n\n'
        '1. Vá em Configurações > Aplicativos\n'
        '2. Encontre o RotaSys na lista\n'
        '3. Toque em Bateria ou Uso de bateria\n'
        '4. Selecione "Não otimizar" ou "Não restrito"\n\n'
        '🔍 Localizações alternativas:\n'
        '• Configurações > Bateria > Otimização de bateria\n'
        '• Configurações > Aplicativos > Gerenciar aplicativos > RotaSys\n'
        '• Configurações > Manutenção do dispositivo > Bateria';
  }
}
