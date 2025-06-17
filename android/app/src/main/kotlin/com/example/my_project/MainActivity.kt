package com.pigmadesenvolvimentos.lakretracking

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import androidx.annotation.NonNull
import io.flutter.embedding.android.FlutterFragmentActivity  
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class MainActivity: FlutterFragmentActivity() { 
    private val CHANNEL = "battery_optimization"
    private val REQUEST_BATTERY_OPTIMIZATION = 1001
    private var pendingResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(@NonNull flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            onMethodCall(call, result)
        }
    }

    private fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "isBatteryOptimizationDisabled" -> {
                result.success(isBatteryOptimizationDisabled())
            }
            "requestDisableBatteryOptimization" -> {
                requestDisableBatteryOptimization(result)
            }
            "canIgnoreBatteryOptimizations" -> {
                result.success(canIgnoreBatteryOptimizations())
            }
            else -> {
                result.notImplemented()
            }
        }
    }

    /**
     * Verifica se o aplicativo está na lista branca de otimização de bateria
     */
    private fun isBatteryOptimizationDisabled(): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            val powerManager = getSystemService(Context.POWER_SERVICE) as PowerManager?
            powerManager?.isIgnoringBatteryOptimizations(packageName) ?: false
        } else {
            true // Em versões antigas do Android, não há otimização de bateria
        }
    }

    /**
     * Verifica se o aplicativo pode solicitar para ignorar otimizações de bateria
     */
    private fun canIgnoreBatteryOptimizations(): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            // Se já está desabilitado, retorna true
            if (isBatteryOptimizationDisabled()) {
                true
            } else {
                // Para Android M+, sempre permitir solicitar a permissão
                true
            }
        } else {
            true // Versões antigas sempre retornam true
        }
    }

    /**
     * Solicita ao usuário para desabilitar a otimização de bateria
     */
    private fun requestDisableBatteryOptimization(result: MethodChannel.Result) {
        pendingResult = result
        
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            // Verificar se já está desabilitado
            if (isBatteryOptimizationDisabled()) {
                result.success(true)
                return
            }

            try {
                // Tentar abrir a tela específica do aplicativo
                val specificIntent = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS).apply {
                    data = Uri.parse("package:$packageName")
                }
                
                if (specificIntent.resolveActivity(packageManager) != null) {
                    startActivityForResult(specificIntent, REQUEST_BATTERY_OPTIMIZATION)
                    return
                }
                
                // Fallback: abrir lista geral de otimização de bateria
                val generalIntent = Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)
                if (generalIntent.resolveActivity(packageManager) != null) {
                    startActivity(generalIntent)
                    result.success(false)
                    return
                }
                
                // Último fallback: configurações do aplicativo
                val appSettingsIntent = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                    data = Uri.parse("package:$packageName")
                }
                startActivity(appSettingsIntent)
                result.success(false)
                
            } catch (e: Exception) {
                result.error("ERROR", "Não foi possível abrir configurações de bateria", e.message)
            }
        } else {
            result.success(true) // Versões antigas não precisam dessa permissão
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        
        if (requestCode == REQUEST_BATTERY_OPTIMIZATION && pendingResult != null) {
            // Verificar se a otimização foi desabilitada após o usuário voltar
            val isDisabled = isBatteryOptimizationDisabled()
            pendingResult?.success(isDisabled)
            pendingResult = null
        }
    }

    override fun onResume() {
        super.onResume()
        
        // Se há um resultado pendente, verificar quando o usuário voltar para o app
        pendingResult?.let { result ->
            val isDisabled = isBatteryOptimizationDisabled()
            result.success(isDisabled)
            pendingResult = null
        }
    }
}