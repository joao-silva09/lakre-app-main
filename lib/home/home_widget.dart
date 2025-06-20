import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/services.dart';
import 'package:pigma/backend/schema/structs/positions_struct.dart';
import 'package:url_launcher/url_launcher.dart';
import '/backend/api_requests/api_calls.dart';
import '/backend/backend.dart';
import '/flutter_flow/flutter_flow_animations.dart';
import 'package:flutter_animate/flutter_animate.dart';
import '/components/sem_viagem_widget.dart';
import '/flutter_flow/flutter_flow_theme.dart';
import '/flutter_flow/flutter_flow_util.dart';
import '/flutter_flow/flutter_flow_widgets.dart';
import '/flutter_flow/custom_functions.dart' as functions;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:provider/provider.dart';
import 'home_model.dart';
export 'home_model.dart';
import 'package:flutter_mapbox_navigation/flutter_mapbox_navigation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:pigma/services/battery_optimization_service.dart';
import '../services/background_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

class HomeWidget extends StatefulWidget {
  const HomeWidget({
    super.key,
    this.localizacao,
  });
  final LatLng? localizacao;
  @override
  State<HomeWidget> createState() => _HomeWidgetState();
}

class _HomeWidgetState extends State<HomeWidget> {
  late SnackBar locationIssuesSnackBar;

  String companyPhoneNumber = "";
  double? latitude;
  double? longitude;
  DateTime? savedTime;

  final bool _isMultipleStop = false;
  MapBoxNavigationViewController? _controller;
  late MapBoxOptions _navigationOption;
  final MapBoxNavigation _mapboxNavigation = MapBoxNavigation();
  List<WayPoint> wayPoints = [];
  late HomeModel _model;
  int distance = 0;
  String unit = "";
  bool hasLocationIssues = false;

  final scaffoldKey = GlobalKey<ScaffoldState>();
  LatLng? currentUserLocationValue;

  bool _batteryCheckPerformed = false;

  Timer? _heartbeatTimer;
  Timer? _locationTimer;

  final backgroundService = BackgroundLocationService();

  final animationsMap = {
    'containerOnPageLoadAnimation': AnimationInfo(
      loop: true,
      trigger: AnimationTrigger.onPageLoad,
      effects: [
        MoveEffect(
          curve: Curves.easeInOut,
          delay: 100.ms,
          duration: 600.ms,
          begin: const Offset(0.0, -22.0),
          end: const Offset(0.0, 22.0),
        ),
        FadeEffect(
          curve: Curves.easeInOut,
          delay: 300.ms,
          duration: 600.ms,
          begin: 0.0,
          end: 1.0,
        ),
      ],
    ),
  };

  bool showMap = true;
  late List<ConnectivityResult> connectivityResult;

  @override
  void initState() {
    super.initState();
    _model = createModel(context, () => HomeModel());

    // Verificar permissões de bateria após a inicialização
    Timer(const Duration(seconds: 3), () async {
      if (!_batteryCheckPerformed && mounted) {
        await _performBatteryCheck();
      }
    });

    if (FFAppState().latLngDriver != null) {
      latitude = FFAppState().latLngDriver!.latitude;
      longitude = FFAppState().latLngDriver!.longitude;
    }

    locationIssuesSnackBar = SnackBar(
      content: const Text(
        'Não foi possível obter a localização do dispositivo. Verifique se o GPS encontra-se ativo e se a permissão de acesso foi concedida.',
        style: TextStyle(
          color: Colors.white,
        ),
      ),
      duration: const Duration(milliseconds: 4000),
      backgroundColor: FlutterFlowTheme.of(context).error,
    );

    () async {
      await _getLocation().whenComplete(
          () => currentUserLocationValue = FFAppState().latLngDriver);
      setState(() {});
    }();

    savedTime = DateTime.now();

    MapBoxNavigation.instance.setDefaultOptions(MapBoxOptions(
      mode: MapBoxNavigationMode.driving,
      language: "pt-BR",
      initialLatitude: FFAppState().latLngDriver?.latitude,
      initialLongitude: FFAppState().latLngDriver?.longitude,
      voiceInstructionsEnabled: true,
      bannerInstructionsEnabled: true,
      units: VoiceUnits.metric,
      showEndOfRouteFeedback: false,
      showReportFeedbackButton: false,
      longPressDestinationEnabled: false,
    ));

    _navigationOption = MapBoxNavigation.instance.getDefaultOptions();
    _mapboxNavigation.setDefaultOptions(_navigationOption);
    _mapboxNavigation.registerRouteEventListener(_onEmbeddedRouteEvent);

    // On page load action.
    SchedulerBinding.instance.addPostFrameCallback((_) async {
      if (!FFAppState().acceptedTermsAndPrivacy) {
        showConfirmConsentDialog(context);
      }

      // Configurar heartbeat e sistema de localização unificado
      _setupHeartbeat();
      _startLocationTracking();
    });

    super.initState();
  }

  @override
  void dispose() {
    _controller?.dispose();
    _heartbeatTimer?.cancel();
    _locationTimer?.cancel();
    _model.dispose();
    super.dispose();
  }

  Future<void> _getLocation() async {
    try {
      // Verificar se serviço está habilitado
      bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        setState(() {
          hasLocationIssues = true;
        });
        return;
      }

      // Verificar permissões
      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied) {
          setState(() {
            hasLocationIssues = true;
          });
          return;
        }
      }

      if (permission == LocationPermission.deniedForever) {
        setState(() {
          hasLocationIssues = true;
        });
        return;
      }

      // Obter localização atual
      Position position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          distanceFilter: 0,
        ),
      );

      setState(() {
        latitude = position.latitude;
        longitude = position.longitude;
        hasLocationIssues = false;
        FFAppState().latLngDriver =
            LatLng(position.latitude, position.longitude);
      });

      debugPrint(
          '📍 Localização obtida no foreground: ${position.latitude}, ${position.longitude}');
    } catch (e) {
      debugPrint('❌ Erro ao obter localização: $e');
      setState(() {
        hasLocationIssues = true;
      });
    }
  }

  void _startLocationTracking() {
    if (!FFAppState().routeSelected.hasRouteId()) {
      return;
    }

    debugPrint('🔄 Iniciando tracking de localização no foreground');

    // Timer para coleta de localização a cada 1 minuto (foreground)
    // enquanto o background service coleta a cada 5 minutos
    _locationTimer = Timer.periodic(const Duration(minutes: 1), (timer) async {
      if (!FFAppState().routeSelected.hasRouteId()) {
        timer.cancel();
        return;
      }

      await _getLocation();

      if (latitude != null &&
          longitude != null &&
          latitude!.truncate() != 0 &&
          longitude!.truncate() != 0) {
        // Adicionar posição ao estado global
        setState(() {
          FFAppState().addToPositions(PositionsStruct(
            cpf: FFAppState().cpf,
            routeId: FFAppState().routeSelected.routeId,
            latitude: FFAppState().latLngDriver?.latitude,
            longitude: FFAppState().latLngDriver?.longitude,
            date: DateTime.now()
                .subtract(DateTime.now().timeZoneOffset)
                .subtract(const Duration(hours: 3)),
            finish: false,
          ));
        });

        debugPrint(
            '📍 Posição adicionada ao estado (foreground): ${latitude}, ${longitude}');
      }
    });

    // Timer separado para envio para API a cada 1 minuto
    Timer.periodic(const Duration(minutes: 1), (timer) async {
      if (!FFAppState().routeSelected.hasRouteId()) {
        timer.cancel();
        return;
      }

      // Verificar conectividade
      connectivityResult = await Connectivity().checkConnectivity();

      // Enviar para API
      postRoute(false);
      setState(() {});
    });
  }

  bool calculateDistanceInMostReadableUnit(
    LatLng coord1,
    double lat,
    double long,
  ) {
    var distanceInMeters =
        functions.calculateDistanceInMeters(coord1, lat, long);

    if (distanceInMeters > 9999) {
      distance = distanceInMeters ~/ 1000;
      unit = "Km";
    } else {
      distance = distanceInMeters;
      unit = "Metros";
    }

    return true;
  }

  void _setupHeartbeat() {
    _heartbeatTimer = Timer.periodic(const Duration(seconds: 30), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }

      // Apenas verificar se o background service está ativo
      BackgroundLocationService().isTrackingActive().then((isActive) {
        debugPrint('💓 Heartbeat: Background service ativo: $isActive');
      });
    });
  }

  Future<void> _performBatteryCheck() async {
    if (_batteryCheckPerformed) return;

    try {
      final backgroundService = BackgroundLocationService();
      await backgroundService.checkAndRequestBatteryPermissions(context);
      _batteryCheckPerformed = true;
    } catch (e) {
      debugPrint('❌ Erro na verificação de bateria: $e');
    }
  }

  void _onEmbeddedRouteEvent(e) async {
    switch (e.eventType) {
      case MapBoxEvent.progress_change:
        var progressEvent = e.data as RouteProgressEvent;
        if (progressEvent.currentStepInstruction != null) {
          distance = progressEvent.distanceRemaining!.toInt();
          unit = progressEvent.durationRemaining! > 60
              ? '${(progressEvent.durationRemaining! / 60).toInt()} min'
              : '${progressEvent.durationRemaining!.toInt()} seg';
        }
        setState(() {});
        break;
      case MapBoxEvent.route_building:
      case MapBoxEvent.route_built:
        setState(() {});
        break;
      case MapBoxEvent.route_build_failed:
        setState(() {});
        break;
      case MapBoxEvent.navigation_running:
        setState(() {});
        break;
      case MapBoxEvent.on_arrival:
        break;
      case MapBoxEvent.navigation_finished:
      case MapBoxEvent.navigation_cancelled:
        break;
      default:
        break;
    }
  }

  void postRoute(bool isFinished) async {
    connectivityResult = await Connectivity().checkConnectivity();

    if (connectivityResult.any((result) =>
        result == ConnectivityResult.mobile ||
        result == ConnectivityResult.wifi ||
        result == ConnectivityResult.ethernet)) {
      if (FFAppState().positions.isNotEmpty) {
        _model.positionsRouteCall =
            await APIsPigmanGroup.positionsRouteCall.call(
          positionsList: FFAppState().positions,
        );

        if ((_model.positionsRouteCall?.succeeded ?? true)) {
          debugPrint('✅ Posições enviadas para API via foreground');
          setState(() {
            FFAppState().positions = [];
          });
        }
      }
    }
  }

  Future<void> concluirViagem() async {
    try {
      debugPrint('🏁 Iniciando conclusão da viagem');

      // Parar o background service
      final backgroundService = BackgroundLocationService();
      await backgroundService.stopLocationUpdates();

      // Cancelar timers locais
      _locationTimer?.cancel();

      // Obter localização final
      await _getLocation();

      if (latitude != null && longitude != null) {
        setState(() {
          FFAppState().addToPositions(PositionsStruct(
            cpf: FFAppState().cpf,
            routeId: FFAppState().routeSelected.routeId,
            latitude: latitude,
            longitude: longitude,
            date: DateTime.now()
                .subtract(DateTime.now().timeZoneOffset)
                .subtract(const Duration(hours: 3)),
            finish: true, // Marcando como finalizada
          ));
        });

        // Enviar posição final
        postRoute(true);
      }

      debugPrint('✅ Viagem concluída');
    } catch (e) {
      debugPrint('❌ Erro ao concluir viagem: $e');
    }
  }

  // Mostrar aviso sobre otimização de bateria
  void _showBatteryOptimizationWarning() {
    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Row(
          children: [
            Icon(Icons.battery_alert, color: Colors.white, size: 20),
            SizedBox(width: 8),
            Expanded(
              child: Text(
                'Para garantir o funcionamento em segundo plano, configure a otimização de bateria',
                style: TextStyle(fontSize: 14),
              ),
            ),
          ],
        ),
        action: SnackBarAction(
          label: 'Configurar',
          textColor: Colors.white,
          onPressed: () async {
            await BatteryOptimizationService.checkAndRequestBatteryPermissions(
                context);
          },
        ),
        duration: const Duration(seconds: 8),
        backgroundColor: Colors.orange.shade700,
      ),
    );
  }

  // Dialog de configuração de bateria
  Future<bool> _showBatteryConfigurationDialog() async {
    return await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (BuildContext context) {
            return AlertDialog(
              title: const Row(
                children: [
                  Icon(Icons.battery_alert, color: Colors.orange),
                  SizedBox(width: 8),
                  Text('Configuração Importante'),
                ],
              ),
              content: const SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Para que o rastreamento funcione perfeitamente em segundo plano, '
                      'é recomendado configurar a otimização de bateria.',
                      style: TextStyle(fontSize: 16),
                    ),
                    SizedBox(height: 16),
                    Text(
                      '⚠️ Sem essa configuração, o aplicativo pode parar de rastrear '
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
                  onPressed: () => Navigator.of(context).pop(true),
                  child: const Text('Pular por Agora'),
                ),
                ElevatedButton(
                  onPressed: () async {
                    Navigator.of(context).pop(false);

                    // Solicitar configuração de bateria
                    final configured = await BatteryOptimizationService
                        .checkAndRequestBatteryPermissions(context);

                    if (configured && mounted) {
                      // Se configurou com sucesso, iniciar a viagem automaticamente
                      Timer(const Duration(seconds: 1), () {
                        if (mounted) {
                          _startTrip();
                        }
                      });
                    }
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF4646B4),
                    foregroundColor: Colors.white,
                  ),
                  child: const Text('Configurar Agora'),
                ),
              ],
            );
          },
        ) ??
        false;
  }

  // Iniciar viagem (extraída para reutilização)
  Future<void> _startTrip() async {
    try {
      _model.apiResult7s3 = await APIsPigmanGroup.acceptRouteCall.call(
        cpf: FFAppState().cpf,
        routeId: FFAppState().routeSelected.routeId,
      );

      if ((_model.apiResult7s3?.succeeded ?? true)) {
        FFAppState().update(() {
          FFAppState().stopInProgress = FFAppState().routeSelected.stops.first;
        });

        setState(() {
          FFAppState().addToPositions(PositionsStruct(
            cpf: FFAppState().cpf,
            routeId: FFAppState().routeSelected.routeId,
            latitude: FFAppState().latLngDriver?.latitude,
            longitude: FFAppState().latLngDriver?.longitude,
            date: DateTime.now()
                .subtract(DateTime.now().timeZoneOffset)
                .subtract(const Duration(hours: 3)),
            finish: false,
          ));
        });

        postRoute(false);

        // Iniciar o serviço de localização com verificação de bateria
        await BackgroundLocationService().startLocationUpdates(
          cpf: FFAppState().cpf,
          routeId: FFAppState().routeSelected.routeId.toString(),
          finishViagem: false,
          context: context,
        );
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: const Text(
                'Não foi possível iniciar a viagem, verifique sua conexão com internet e tente novamente.',
                style: TextStyle(color: Colors.white),
              ),
              duration: const Duration(milliseconds: 4000),
              backgroundColor: FlutterFlowTheme.of(context).error,
            ),
          );
        }
      }
      _model.menu = true;
      setState(() {});
    } catch (e) {
      debugPrint('❌ Erro ao iniciar viagem: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text(
              'Erro ao iniciar viagem. Tente novamente.',
              style: TextStyle(color: Colors.white),
            ),
            backgroundColor: FlutterFlowTheme.of(context).error,
          ),
        );
      }
    }
  }

  // Adicionar item no menu superior para verificar status
  Widget _buildBatteryStatusIndicator() {
    return FutureBuilder<bool>(
      future: BatteryOptimizationService.isBatteryOptimizationDisabled(),
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return const SizedBox.shrink();
        }

        final isOptimized = snapshot.data ?? false;

        return Padding(
          padding: const EdgeInsets.only(right: 8.0),
          child: InkWell(
            splashColor: Colors.transparent,
            focusColor: Colors.transparent,
            hoverColor: Colors.transparent,
            highlightColor: Colors.transparent,
            onTap: () async {
              if (!isOptimized) {
                await BatteryOptimizationService
                    .checkAndRequestBatteryPermissions(context);
                setState(() {}); // Rebuild para atualizar o indicador
              } else {
                _showBatteryStatusDialog(isOptimized);
              }
            },
            child: Icon(
              isOptimized ? Icons.battery_full : Icons.battery_alert,
              color: isOptimized ? Colors.green : Colors.orange,
              size: 28.0,
            ),
          ),
        );
      },
    );
  }

  // Dialog de status da bateria
  void _showBatteryStatusDialog(bool isOptimized) {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: Row(
            children: [
              Icon(
                isOptimized ? Icons.battery_full : Icons.battery_alert,
                color: isOptimized ? Colors.green : Colors.orange,
              ),
              const SizedBox(width: 8),
              const Text('Status da Bateria'),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                isOptimized
                    ? '✅ Configuração adequada para funcionamento em segundo plano'
                    : '⚠️ Otimização de bateria ativa - pode afetar o funcionamento',
                style: TextStyle(
                  fontSize: 16,
                  color: isOptimized ? Colors.green : Colors.orange,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 16),
              if (!isOptimized) ...[
                const Text(
                  'Para melhor funcionamento, recomendamos configurar:\n'
                  'Configurações > Aplicativos > RotaSys > Bateria > "Não otimizar"',
                  style: TextStyle(fontSize: 14),
                ),
              ] else ...[
                const Text(
                  'O aplicativo está configurado corretamente para funcionar '
                  'em segundo plano sem interrupções.',
                  style: TextStyle(fontSize: 14),
                ),
              ],
            ],
          ),
          actions: [
            if (!isOptimized) ...[
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Entendi'),
              ),
              ElevatedButton(
                onPressed: () async {
                  Navigator.of(context).pop();
                  await BatteryOptimizationService
                      .checkAndRequestBatteryPermissions(context);
                  setState(() {}); // Rebuild para atualizar
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF4646B4),
                  foregroundColor: Colors.white,
                ),
                child: const Text('Configurar'),
              ),
            ] else ...[
              ElevatedButton(
                onPressed: () => Navigator.of(context).pop(),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.green,
                  foregroundColor: Colors.white,
                ),
                child: const Text('OK'),
              ),
            ],
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    context.watch<FFAppState>();

    return GestureDetector(
      onTap: () => _model.unfocusNode.canRequestFocus
          ? FocusScope.of(context).requestFocus(_model.unfocusNode)
          : FocusScope.of(context).unfocus(),
      child: Scaffold(
        key: scaffoldKey,
        backgroundColor: Colors.white,
        body: SafeArea(
            top: true,
            child: Column(
              mainAxisSize: MainAxisSize.max,
              children: [
                Container(
                  width: double.infinity,
                  height: 60.0,
                  decoration: BoxDecoration(
                    color: FlutterFlowTheme.of(context).secondaryBackground,
                    boxShadow: [
                      BoxShadow(
                        color: FlutterFlowTheme.of(context).accent2,
                        blurRadius: 0.1,
                        blurStyle: BlurStyle.solid,
                      )
                    ],
                  ),
                  child: Padding(
                    padding: const EdgeInsetsDirectional.fromSTEB(
                        12.0, 0.0, 12.0, 0.0),
                    child: Row(
                      mainAxisSize: MainAxisSize.max,
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Padding(
                          padding: const EdgeInsetsDirectional.fromSTEB(
                              0.0, 0.0, 8.0, 0.0),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(8.0),
                            child: Image.asset(
                              'assets/images/rotasys_NoText_Bg.png',
                              width: 50.0,
                              height: 50.0,
                              fit: BoxFit.cover,
                            ),
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsetsDirectional.fromSTEB(
                              0.0, 0.0, 8.0, 0.0),
                          child: Row(
                            mainAxisSize: MainAxisSize.max,
                            children: [
                              _buildBatteryStatusIndicator(),
                              Padding(
                                padding: const EdgeInsets.only(right: 16.0),
                                child: InkWell(
                                  splashColor: Colors.transparent,
                                  focusColor: Colors.transparent,
                                  hoverColor: Colors.transparent,
                                  highlightColor: Colors.transparent,
                                  onTap: () {
                                    showRemoveConsentDialog(context);
                                  },
                                  child: const Icon(
                                    Icons.description_outlined,
                                    color: Color(0xFF2D2D6B),
                                    size: 28.0,
                                  ),
                                ),
                              ),
                              Padding(
                                padding: const EdgeInsets.only(right: 16.0),
                                child: InkWell(
                                  splashColor: Colors.transparent,
                                  focusColor: Colors.transparent,
                                  hoverColor: Colors.transparent,
                                  highlightColor: Colors.transparent,
                                  onTap: FFAppState()
                                              .routeSelected
                                              .companyPhone ==
                                          ''
                                      ? null
                                      : () =>
                                          openWhatsAppChatWithCurrentCompany(),
                                  child: FaIcon(
                                    FontAwesomeIcons.whatsapp,
                                    color: FFAppState()
                                                .routeSelected
                                                .companyPhone ==
                                            ''
                                        ? Colors.grey
                                        : FlutterFlowTheme.of(context).tertiary,
                                    size: 28.0,
                                  ),
                                ),
                              ),
                              InkWell(
                                splashColor: Colors.transparent,
                                focusColor: Colors.transparent,
                                hoverColor: Colors.transparent,
                                highlightColor: Colors.transparent,
                                onTap: () async {
                                  _model.botaoRota = true;
                                  setState(() {
                                    FFAppState().viagemDisponivel =
                                        RouteStruct();
                                    FFAppState().cpf = '';
                                    FFAppState().routeSelected = RouteStruct();
                                  });

                                  context.pushReplacementNamed('codigoAcesso');
                                },
                                child: const Icon(
                                  Icons.logout_rounded,
                                  color: Color(0xFF2D2D6B),
                                  size: 28.0,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                Expanded(
                  child: Stack(
                    children: [
                      if (!FFAppState().routeSelected.hasRouteId())
                        SingleChildScrollView(
                            child: Column(
                          mainAxisSize: MainAxisSize.max,
                          children: [
                            wrapWithModel(
                              model: _model.semViagemModel,
                              updateCallback: () => setState(() {}),
                              child: const SemViagemWidget(),
                            ),
                            Padding(
                                padding: const EdgeInsetsDirectional.fromSTEB(
                                    20.0, 50.0, 20.0, 50.0),
                                child: Row(
                                    mainAxisSize: MainAxisSize.max,
                                    mainAxisAlignment:
                                        MainAxisAlignment.spaceAround,
                                    children: [
                                      FFButtonWidget(
                                        onPressed: () async {
                                          setState(() {
                                            FFAppState().fromRefresh = true;
                                          });
                                          context.pushReplacementNamed(
                                              'codigoAcesso');
                                        },
                                        text: 'Atualizar',
                                        icon: const FaIcon(
                                          FontAwesomeIcons.arrowsRotate,
                                        ),
                                        options: FFButtonOptions(
                                          width: 175.0,
                                          height: 50.0,
                                          padding: const EdgeInsetsDirectional
                                              .fromSTEB(8.0, 0.0, 8.0, 0.0),
                                          iconPadding:
                                              const EdgeInsetsDirectional
                                                  .fromSTEB(0.0, 0.0, 0.0, 0.0),
                                          color: const Color(0xFF4646B4),
                                          textStyle:
                                              FlutterFlowTheme.of(context)
                                                  .titleSmall
                                                  .override(
                                                    fontFamily: 'Inter',
                                                    color: Colors.white,
                                                  ),
                                          elevation: 3.0,
                                          borderSide: const BorderSide(
                                            color: Colors.transparent,
                                            width: 1.0,
                                          ),
                                          borderRadius:
                                              BorderRadius.circular(8.0),
                                        ),
                                      ),
                                    ]))
                          ],
                        ))
                      else
                        Column(
                          mainAxisSize: MainAxisSize.max,
                          children: [
                            Expanded(
                              child: Stack(
                                children: [
                                  Container(
                                    color: Colors.grey,
                                    child: MapBoxNavigationView(
                                      options: _navigationOption,
                                      key: const Key("mapStatic"),
                                      onCreated: (MapBoxNavigationViewController
                                          controller) async {
                                        _controller = controller;
                                        _model.menu = true;

                                        // await _getLocation();

                                        var index = 1;

                                        wayPoints.add(WayPoint(
                                            name: "Inicio",
                                            latitude: FFAppState()
                                                .latLngDriver
                                                ?.latitude,
                                            longitude: FFAppState()
                                                .latLngDriver
                                                ?.longitude,
                                            isSilent: false));

                                        for (var element in FFAppState()
                                            .routeSelected
                                            .stops) {
                                          if (!element.isComplete) {
                                            wayPoints.add(WayPoint(
                                                name: "Destino $index",
                                                latitude: element.latitude,
                                                longitude: element.longitude,
                                                isSilent: false));
                                          }
                                          index++;
                                        }

                                        _controller?.buildRoute(
                                            wayPoints: wayPoints,
                                            options: _navigationOption);
                                      },
                                      onRouteEvent: _onEmbeddedRouteEvent,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            if (FFAppState().stopInProgress.hasStopId() &&
                                _model.menu)
                              Container(
                                width: double.infinity,
                                decoration: BoxDecoration(
                                  color: FlutterFlowTheme.of(context)
                                      .secondaryBackground,
                                ),
                                child: Padding(
                                  padding: const EdgeInsets.all(16.0),
                                  child: Column(
                                    mainAxisSize: MainAxisSize.max,
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        mainAxisSize: MainAxisSize.max,
                                        mainAxisAlignment:
                                            MainAxisAlignment.spaceBetween,
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Expanded(
                                            child: Container(
                                              decoration: const BoxDecoration(),
                                              child: Row(
                                                mainAxisSize: MainAxisSize.max,
                                                children: [
                                                  Expanded(
                                                    child: Padding(
                                                      padding:
                                                          const EdgeInsetsDirectional
                                                              .fromSTEB(0.0,
                                                              0.0, 20.0, 0.0),
                                                      child: Container(
                                                        height: 100.0,
                                                        decoration:
                                                            BoxDecoration(
                                                          color: FlutterFlowTheme
                                                                  .of(context)
                                                              .accent3,
                                                          borderRadius:
                                                              BorderRadius
                                                                  .circular(
                                                                      8.0),
                                                        ),
                                                        child: Padding(
                                                          padding:
                                                              const EdgeInsetsDirectional
                                                                  .fromSTEB(
                                                                  8.0,
                                                                  0.0,
                                                                  8.0,
                                                                  0.0),
                                                          child: Column(
                                                            mainAxisSize:
                                                                MainAxisSize
                                                                    .max,
                                                            children: [
                                                              Expanded(
                                                                child: Stack(
                                                                  children: [
                                                                    Padding(
                                                                      padding: const EdgeInsetsDirectional
                                                                          .fromSTEB(
                                                                          8.0,
                                                                          12.0,
                                                                          0.0,
                                                                          0.0),
                                                                      child:
                                                                          Container(
                                                                        width:
                                                                            2.0,
                                                                        height:
                                                                            68.0,
                                                                        decoration:
                                                                            const BoxDecoration(
                                                                          color:
                                                                              Color(0x5B757575),
                                                                        ),
                                                                      ),
                                                                    ),
                                                                    Padding(
                                                                      padding: const EdgeInsetsDirectional
                                                                          .fromSTEB(
                                                                          8.0,
                                                                          0.0,
                                                                          0.0,
                                                                          0.0),
                                                                      child:
                                                                          Container(
                                                                        width:
                                                                            2.0,
                                                                        height:
                                                                            50.0,
                                                                        decoration:
                                                                            BoxDecoration(
                                                                          color:
                                                                              FlutterFlowTheme.of(context).primary,
                                                                        ),
                                                                      ).animateOnPageLoad(
                                                                              animationsMap['containerOnPageLoadAnimation']!),
                                                                    ),
                                                                    Padding(
                                                                      padding: const EdgeInsetsDirectional
                                                                          .fromSTEB(
                                                                          0.0,
                                                                          0.0,
                                                                          0.0,
                                                                          8.0),
                                                                      child:
                                                                          Column(
                                                                        mainAxisSize:
                                                                            MainAxisSize.max,
                                                                        mainAxisAlignment:
                                                                            MainAxisAlignment.spaceBetween,
                                                                        children: [
                                                                          Padding(
                                                                            padding: const EdgeInsetsDirectional.fromSTEB(
                                                                                0.0,
                                                                                8.0,
                                                                                0.0,
                                                                                0.0),
                                                                            child:
                                                                                Row(
                                                                              mainAxisSize: MainAxisSize.max,
                                                                              children: [
                                                                                Padding(
                                                                                  padding: const EdgeInsetsDirectional.fromSTEB(0.0, 0.0, 8.0, 0.0),
                                                                                  child: Container(
                                                                                    width: 20.0,
                                                                                    height: 20.0,
                                                                                    decoration: BoxDecoration(
                                                                                      color: FlutterFlowTheme.of(context).primary,
                                                                                      borderRadius: BorderRadius.circular(24.0),
                                                                                    ),
                                                                                    child: const Icon(
                                                                                      Icons.pin_drop,
                                                                                      color: Colors.white,
                                                                                      size: 16.0,
                                                                                    ),
                                                                                  ),
                                                                                ),
                                                                                Text(
                                                                                  'Você',
                                                                                  style: FlutterFlowTheme.of(context).bodyMedium,
                                                                                ),
                                                                              ],
                                                                            ),
                                                                          ),
                                                                          Padding(
                                                                            padding: const EdgeInsetsDirectional.fromSTEB(
                                                                                0.0,
                                                                                8.0,
                                                                                0.0,
                                                                                0.0),
                                                                            child:
                                                                                Row(
                                                                              mainAxisSize: MainAxisSize.max,
                                                                              children: [
                                                                                Padding(
                                                                                  padding: const EdgeInsetsDirectional.fromSTEB(0.0, 0.0, 8.0, 0.0),
                                                                                  child: Container(
                                                                                    width: 20.0,
                                                                                    height: 20.0,
                                                                                    decoration: BoxDecoration(
                                                                                      color: FlutterFlowTheme.of(context).primary,
                                                                                      borderRadius: BorderRadius.circular(24.0),
                                                                                    ),
                                                                                    child: const Align(
                                                                                      alignment: AlignmentDirectional(0.0, 0.0),
                                                                                      child: FaIcon(
                                                                                        FontAwesomeIcons.flagCheckered,
                                                                                        color: Colors.white,
                                                                                        size: 12.0,
                                                                                      ),
                                                                                    ),
                                                                                  ),
                                                                                ),
                                                                                Text(
                                                                                  FFAppState().stopInProgress.stopName,
                                                                                  style: FlutterFlowTheme.of(context).bodyMedium,
                                                                                ),
                                                                              ],
                                                                            ),
                                                                          ),
                                                                        ],
                                                                      ),
                                                                    ),
                                                                  ],
                                                                ),
                                                              ),
                                                            ],
                                                          ),
                                                        ),
                                                      ),
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ),
                                          ),
                                          Container(
                                            width: 160.0,
                                            decoration: BoxDecoration(
                                              color: functions.calculateDistanceInMeters(
                                                          LatLng(latitude!,
                                                              longitude!),
                                                          FFAppState()
                                                              .stopInProgress
                                                              .latitude,
                                                          FFAppState()
                                                              .stopInProgress
                                                              .longitude) <
                                                      500
                                                  ? FlutterFlowTheme.of(context)
                                                      .tertiary
                                                  : FlutterFlowTheme.of(context)
                                                      .alternate,
                                              borderRadius:
                                                  BorderRadius.circular(8.0),
                                            ),
                                            child: Padding(
                                              padding:
                                                  const EdgeInsetsDirectional
                                                      .fromSTEB(
                                                      20.0, 0.0, 20.0, 0.0),
                                              child: Column(
                                                mainAxisSize: MainAxisSize.max,
                                                children: [
                                                  Padding(
                                                    padding:
                                                        const EdgeInsetsDirectional
                                                            .fromSTEB(
                                                            0.0, 8.0, 0.0, 8.0),
                                                    child: Text(
                                                      'Distância em Raio',
                                                      style: FlutterFlowTheme
                                                              .of(context)
                                                          .bodyMedium
                                                          .override(
                                                            fontFamily:
                                                                'Poppins',
                                                            color: Colors.white,
                                                            fontSize: 12.0,
                                                          ),
                                                    ),
                                                  ),
                                                  Text(
                                                    calculateDistanceInMostReadableUnit(
                                                            LatLng(latitude!,
                                                                longitude!),
                                                            FFAppState()
                                                                .stopInProgress
                                                                .latitude,
                                                            FFAppState()
                                                                .stopInProgress
                                                                .longitude)
                                                        ? distance.toString()
                                                        : "",
                                                    style: FlutterFlowTheme.of(
                                                            context)
                                                        .bodyMedium
                                                        .override(
                                                          fontFamily: 'Poppins',
                                                          color: Colors.white,
                                                          fontSize: 40.0,
                                                          lineHeight: 1.0,
                                                        ),
                                                  ),
                                                  Padding(
                                                    padding:
                                                        const EdgeInsetsDirectional
                                                            .fromSTEB(
                                                            0.0, 0.0, 0.0, 8.0),
                                                    child: Text(
                                                      unit,
                                                      style: FlutterFlowTheme
                                                              .of(context)
                                                          .bodyMedium
                                                          .override(
                                                            fontFamily:
                                                                'Poppins',
                                                            color: Colors.white,
                                                            fontSize: 12.0,
                                                          ),
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                      Padding(
                                        padding: const EdgeInsetsDirectional
                                            .fromSTEB(0.0, 20.0, 0.0, 20.0),
                                        child: Row(
                                          mainAxisSize: MainAxisSize.max,
                                          mainAxisAlignment:
                                              MainAxisAlignment.spaceBetween,
                                          children: [
                                            if ((FFAppState()
                                                    .routeSelected
                                                    .stops
                                                    .where((e) => !e.isComplete)
                                                    .toList()
                                                    .length >
                                                1))
                                              Expanded(
                                                child: FFButtonWidget(
                                                  text: 'Finalizar Parada',
                                                  onPressed: () async {
                                                    // await _getLocation();

                                                    setState(() {
                                                      FFAppState()
                                                          .addToPositions(
                                                              PositionsStruct(
                                                        cpf: FFAppState().cpf,
                                                        routeId: FFAppState()
                                                            .routeSelected
                                                            .routeId,
                                                        latitude: FFAppState()
                                                            .latLngDriver
                                                            ?.latitude,
                                                        longitude: FFAppState()
                                                            .latLngDriver
                                                            ?.longitude,
                                                        date: DateTime.now()
                                                            .subtract(DateTime
                                                                    .now()
                                                                .timeZoneOffset)
                                                            .subtract(
                                                                const Duration(
                                                                    hours: 3)),
                                                        finish: true,
                                                      ));

                                                      FFAppState()
                                                          .updateRouteSelectedStruct(
                                                        (e) => e
                                                          ..updateStops(
                                                            (e) => e[FFAppState()
                                                                    .stopInProgress
                                                                    .stopOrder -
                                                                1]
                                                              ..isComplete =
                                                                  true,
                                                          ),
                                                      );

                                                      FFAppState().update(() {
                                                        FFAppState()
                                                                .stopInProgress =
                                                            FFAppState()
                                                                .routeSelected
                                                                .stops
                                                                .where((e) => !e
                                                                    .isComplete)
                                                                .toList()
                                                                .first;
                                                      });
                                                    });

                                                    bool isFirstWhile = true;

                                                    while (_model.index <
                                                        FFAppState()
                                                            .positions
                                                            .length) {
                                                      connectivityResult =
                                                          await Connectivity()
                                                              .checkConnectivity();
                                                      if (connectivityResult
                                                              .contains(
                                                                  ConnectivityResult
                                                                      .wifi) ||
                                                          connectivityResult
                                                              .contains(
                                                                  ConnectivityResult
                                                                      .mobile)) {
                                                        if (isFirstWhile) {
                                                          var index = 1;
                                                          isFirstWhile = false;

                                                          wayPoints.clear();

                                                          wayPoints.add(WayPoint(
                                                              name: "Início",
                                                              latitude: FFAppState()
                                                                  .latLngDriver
                                                                  ?.latitude,
                                                              longitude: FFAppState()
                                                                  .latLngDriver
                                                                  ?.longitude,
                                                              isSilent: false));

                                                          for (var element
                                                              in FFAppState()
                                                                  .routeSelected
                                                                  .stops) {
                                                            if (!element
                                                                .isComplete) {
                                                              wayPoints.add(WayPoint(
                                                                  name:
                                                                      "Destino $index",
                                                                  latitude: element
                                                                      .latitude,
                                                                  longitude: element
                                                                      .longitude,
                                                                  isSilent:
                                                                      false));
                                                            }
                                                            index++;
                                                          }

                                                          _controller?.buildRoute(
                                                              wayPoints:
                                                                  wayPoints,
                                                              options:
                                                                  _navigationOption);
                                                        }

                                                        _model.enviarLocalizacao1 =
                                                            await APIsPigmanGroup
                                                                .postPositionCall
                                                                .call(
                                                          cpf: FFAppState().cpf,
                                                          routeId: FFAppState()
                                                              .positions
                                                              .first
                                                              .routeId,
                                                          latitude: FFAppState()
                                                              .positions
                                                              .first
                                                              .latitude,
                                                          longitude:
                                                              FFAppState()
                                                                  .positions
                                                                  .first
                                                                  .longitude,
                                                          isFinished:
                                                              FFAppState()
                                                                  .positions
                                                                  .first
                                                                  .finish,
                                                          infoDt:
                                                              dateTimeFormat(
                                                            'yyyy-MM-dd HH:mm:ss',
                                                            FFAppState()
                                                                .positions
                                                                .first
                                                                .date,
                                                            locale: FFLocalizations
                                                                    .of(context)
                                                                .languageCode,
                                                          ),
                                                        );

                                                        if ((_model
                                                                .enviarLocalizacao1
                                                                ?.succeeded ??
                                                            true)) {
                                                          setState(() {
                                                            FFAppState()
                                                                .removeAtIndexFromPositions(
                                                                    0);
                                                          });
                                                        } else {
                                                          setState(() {
                                                            _model.index =
                                                                _model.index +
                                                                    1;
                                                          });
                                                        }
                                                      } else {
                                                        break;
                                                      }
                                                    }
                                                    setState(() {});
                                                  },
                                                  icon: const FaIcon(
                                                    FontAwesomeIcons
                                                        .flagCheckered,
                                                    size: 16.0,
                                                  ),
                                                  options: FFButtonOptions(
                                                    height: 48.0,
                                                    padding:
                                                        const EdgeInsetsDirectional
                                                            .fromSTEB(24.0, 0.0,
                                                            24.0, 0.0),
                                                    iconPadding:
                                                        const EdgeInsetsDirectional
                                                            .fromSTEB(
                                                            0.0, 0.0, 0.0, 0.0),
                                                    color: FlutterFlowTheme.of(
                                                            context)
                                                        .tertiary,
                                                    textStyle: FlutterFlowTheme
                                                            .of(context)
                                                        .titleSmall
                                                        .override(
                                                          fontFamily: 'Poppins',
                                                          color: Colors.white,
                                                        ),
                                                    elevation: 3.0,
                                                    borderSide:
                                                        const BorderSide(
                                                      color: Colors.transparent,
                                                      width: 1.0,
                                                    ),
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                            8.0),
                                                  ),
                                                ),
                                              ),
                                            if ((FFAppState()
                                                    .routeSelected
                                                    .stops
                                                    .where((e) => !e.isComplete)
                                                    .toList()
                                                    .length ==
                                                1))
                                              Expanded(
                                                child: FFButtonWidget(
                                                  text: 'Finalizar Viagem',
                                                  onPressed: () async {
                                                    //  await _getLocation();

                                                    // Adicionar posição no array
                                                    setState(() {
                                                      FFAppState()
                                                          .addToPositions(
                                                              PositionsStruct(
                                                        cpf: FFAppState().cpf,
                                                        routeId: FFAppState()
                                                            .routeSelected
                                                            .routeId,
                                                        latitude: FFAppState()
                                                            .latLngDriver
                                                            ?.latitude,
                                                        longitude: FFAppState()
                                                            .latLngDriver
                                                            ?.longitude,
                                                        date: DateTime.now()
                                                            .subtract(DateTime
                                                                    .now()
                                                                .timeZoneOffset)
                                                            .subtract(
                                                                const Duration(
                                                                    hours: 3)),
                                                        finish: true,
                                                        finishViagem: true,
                                                      ));
                                                    });

                                                    FFAppState()
                                                            .viagemFinalizada =
                                                        true;

                                                    while (_model.index <
                                                        FFAppState()
                                                            .positions
                                                            .length) {
                                                      connectivityResult =
                                                          await Connectivity()
                                                              .checkConnectivity();
                                                      if (connectivityResult
                                                              .contains(
                                                                  ConnectivityResult
                                                                      .wifi) ||
                                                          connectivityResult
                                                              .contains(
                                                                  ConnectivityResult
                                                                      .mobile)) {
                                                        _model.enviarLocalizacaoFinal =
                                                            await APIsPigmanGroup
                                                                .postPositionCall
                                                                .call(
                                                          cpf: FFAppState().cpf,
                                                          routeId: FFAppState()
                                                              .positions
                                                              .first
                                                              .routeId,
                                                          latitude: FFAppState()
                                                              .positions
                                                              .first
                                                              .latitude,
                                                          longitude:
                                                              FFAppState()
                                                                  .positions
                                                                  .first
                                                                  .longitude,
                                                          isFinished:
                                                              FFAppState()
                                                                  .positions
                                                                  .first
                                                                  .finish,
                                                          infoDt:
                                                              dateTimeFormat(
                                                            'yyyy-MM-dd HH:mm:ss',
                                                            FFAppState()
                                                                .positions
                                                                .first
                                                                .date,
                                                            locale: FFLocalizations
                                                                    .of(context)
                                                                .languageCode,
                                                          ),
                                                        );

                                                        if ((_model
                                                                .enviarLocalizacaoFinal
                                                                ?.succeeded ??
                                                            true)) {
                                                          if ((_model
                                                                  .enviarLocalizacaoFinal
                                                                  ?.jsonBody ??
                                                              '')) {
                                                            setState(() {
                                                              FFAppState()
                                                                  .positions = [];
                                                              FFAppState()
                                                                      .stopInProgress =
                                                                  StopStruct();
                                                              FFAppState()
                                                                      .routeSelected =
                                                                  RouteStruct();
                                                            });

                                                            await BackgroundLocationService()
                                                                .stopLocationUpdates();

                                                            _model.pegarNovaRota =
                                                                await APIsPigmanGroup
                                                                    .getNextRouteCall
                                                                    .call(
                                                              cpf: FFAppState()
                                                                  .cpf,
                                                            );
                                                            if ((_model
                                                                    .pegarNovaRota
                                                                    ?.succeeded ??
                                                                true)) {
                                                              setState(() {
                                                                FFAppState()
                                                                        .routeSelected =
                                                                    APIsPigmanGroup
                                                                        .getNextRouteCall
                                                                        .rota(
                                                                  (_model.pegarNovaRota
                                                                          ?.jsonBody ??
                                                                      ''),
                                                                )!;
                                                              });
                                                            }
                                                          } else {
                                                            setState(() {
                                                              FFAppState()
                                                                  .removeAtIndexFromPositions(
                                                                      0);
                                                            });
                                                          }
                                                        } else {
                                                          setState(() {
                                                            _model.index =
                                                                _model.index +
                                                                    1;
                                                          });
                                                        }
                                                      }
                                                    }

                                                    setState(() {});
                                                    if (FFAppState()
                                                        .positions
                                                        .isEmpty) {
                                                      context
                                                          .pushReplacementNamed(
                                                              'home');
                                                    } else {
                                                      context
                                                          .pushReplacementNamed(
                                                              'viagemConcluida');
                                                    }
                                                  },
                                                  icon: const FaIcon(
                                                    FontAwesomeIcons
                                                        .flagCheckered,
                                                    size: 16.0,
                                                  ),
                                                  options: FFButtonOptions(
                                                    height: 48.0,
                                                    padding:
                                                        const EdgeInsetsDirectional
                                                            .fromSTEB(24.0, 0.0,
                                                            24.0, 0.0),
                                                    iconPadding:
                                                        const EdgeInsetsDirectional
                                                            .fromSTEB(
                                                            0.0, 0.0, 0.0, 0.0),
                                                    color: FlutterFlowTheme.of(
                                                            context)
                                                        .tertiary,
                                                    textStyle: FlutterFlowTheme
                                                            .of(context)
                                                        .titleSmall
                                                        .override(
                                                          fontFamily: 'Poppins',
                                                          color: Colors.white,
                                                          fontSize: 16.0,
                                                        ),
                                                    elevation: 3.0,
                                                    borderSide:
                                                        const BorderSide(
                                                      color: Colors.transparent,
                                                      width: 1.0,
                                                    ),
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                            8.0),
                                                  ),
                                                ),
                                              ),
                                            if (_model.botaoRota)
                                              Expanded(
                                                child: Padding(
                                                  padding:
                                                      const EdgeInsetsDirectional
                                                          .fromSTEB(
                                                          20.0, 0.0, 0.0, 0.0),
                                                  child: FFButtonWidget(
                                                    text: 'Iniciar navegação',
                                                    onPressed: () async {
                                                      // await _getLocation();

                                                      connectivityResult =
                                                          await Connectivity()
                                                              .checkConnectivity();
                                                      if (connectivityResult
                                                              .contains(
                                                                  ConnectivityResult
                                                                      .wifi) ||
                                                          connectivityResult
                                                              .contains(
                                                                  ConnectivityResult
                                                                      .mobile)) {
                                                        setState(() {
                                                          FFAppState()
                                                              .addToPositions(
                                                                  PositionsStruct(
                                                            cpf: FFAppState()
                                                                .cpf,
                                                            routeId: FFAppState()
                                                                .routeSelected
                                                                .routeId,
                                                            latitude:
                                                                FFAppState()
                                                                    .latLngDriver
                                                                    ?.latitude,
                                                            longitude:
                                                                FFAppState()
                                                                    .latLngDriver
                                                                    ?.longitude,
                                                            date: DateTime.now()
                                                                .subtract(DateTime
                                                                        .now()
                                                                    .timeZoneOffset)
                                                                .subtract(
                                                                    const Duration(
                                                                        hours:
                                                                            3)),
                                                            finish: false,
                                                          ));
                                                        });

                                                        postRoute(false);
                                                        wayPoints.clear();
                                                        var index = 1;

                                                        wayPoints.add(WayPoint(
                                                            name: "Inicio",
                                                            latitude: latitude,
                                                            longitude:
                                                                longitude,
                                                            isSilent: false));

                                                        for (var element
                                                            in FFAppState()
                                                                .routeSelected
                                                                .stops) {
                                                          if (!element
                                                              .isComplete) {
                                                            wayPoints.add(WayPoint(
                                                                name:
                                                                    "Destino $index",
                                                                latitude: element
                                                                    .latitude,
                                                                longitude: element
                                                                    .longitude,
                                                                isSilent:
                                                                    false));
                                                          }
                                                          index++;
                                                        }

                                                        _controller?.buildRoute(
                                                            wayPoints:
                                                                wayPoints,
                                                            options:
                                                                _navigationOption);
                                                      }

                                                      _model.botaoRota = false;
                                                      _model.menu = false;

                                                      await MapBoxNavigation
                                                          .instance
                                                          .startNavigation(
                                                              wayPoints:
                                                                  wayPoints,
                                                              options:
                                                                  _navigationOption);

                                                      setState(() {});
                                                    },
                                                    icon: const Icon(
                                                      Icons.map_outlined,
                                                      size: 12.0,
                                                    ),
                                                    options: FFButtonOptions(
                                                      height: 48.0,
                                                      padding:
                                                          const EdgeInsetsDirectional
                                                              .fromSTEB(16.0,
                                                              0.0, 16.0, 0.0),
                                                      iconPadding:
                                                          const EdgeInsetsDirectional
                                                              .fromSTEB(0.0,
                                                              0.0, 0.0, 0.0),
                                                      color: Colors.transparent,
                                                      textStyle:
                                                          FlutterFlowTheme.of(
                                                                  context)
                                                              .titleSmall
                                                              .override(
                                                                fontFamily:
                                                                    'Poppins',
                                                                color: FlutterFlowTheme.of(
                                                                        context)
                                                                    .primary,
                                                                fontSize: 10.0,
                                                              ),
                                                      elevation: 0.0,
                                                      borderSide: BorderSide(
                                                        color:
                                                            FlutterFlowTheme.of(
                                                                    context)
                                                                .primary,
                                                        width: 2.0,
                                                      ),
                                                      borderRadius:
                                                          BorderRadius.circular(
                                                              8.0),
                                                    ),
                                                  ),
                                                ),
                                              ),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            if (!FFAppState().stopInProgress.hasStopId())
                              Container(
                                width: double.infinity,
                                height: double.infinity,
                                constraints: const BoxConstraints(
                                  maxHeight: 220.0,
                                ),
                                decoration: BoxDecoration(
                                  color: FlutterFlowTheme.of(context)
                                      .secondaryBackground,
                                ),
                                child: Padding(
                                  padding: const EdgeInsets.all(16.0),
                                  child: Column(
                                    mainAxisSize: MainAxisSize.max,
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        mainAxisSize: MainAxisSize.max,
                                        mainAxisAlignment:
                                            MainAxisAlignment.spaceBetween,
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Expanded(
                                            child: Row(
                                              mainAxisSize: MainAxisSize.max,
                                              children: [
                                                Expanded(
                                                  child: Container(
                                                    height: 160.0,
                                                    decoration:
                                                        const BoxDecoration(),
                                                    child: Column(
                                                      mainAxisSize:
                                                          MainAxisSize.max,
                                                      mainAxisAlignment:
                                                          MainAxisAlignment
                                                              .spaceBetween,
                                                      crossAxisAlignment:
                                                          CrossAxisAlignment
                                                              .start,
                                                      children: [
                                                        Column(
                                                          mainAxisSize:
                                                              MainAxisSize.max,
                                                          mainAxisAlignment:
                                                              MainAxisAlignment
                                                                  .spaceBetween,
                                                          crossAxisAlignment:
                                                              CrossAxisAlignment
                                                                  .start,
                                                          children: [
                                                            Text(
                                                              'Uma viagem disponível',
                                                              style: FlutterFlowTheme
                                                                      .of(context)
                                                                  .bodyMedium
                                                                  .override(
                                                                    fontFamily:
                                                                        'Poppins',
                                                                    fontSize:
                                                                        18.0,
                                                                  ),
                                                            ),
                                                            Column(
                                                              mainAxisSize:
                                                                  MainAxisSize
                                                                      .max,
                                                              crossAxisAlignment:
                                                                  CrossAxisAlignment
                                                                      .start,
                                                              children: [
                                                                Padding(
                                                                  padding:
                                                                      const EdgeInsetsDirectional
                                                                          .fromSTEB(
                                                                          0.0,
                                                                          8.0,
                                                                          0.0,
                                                                          0.0),
                                                                  child: Text(
                                                                    valueOrDefault<
                                                                        String>(
                                                                      functions.formatDateString(FFAppState()
                                                                          .routeSelected
                                                                          .expectedArrivalDt),
                                                                      '-',
                                                                    ),
                                                                    style: FlutterFlowTheme.of(
                                                                            context)
                                                                        .bodyMedium
                                                                        .override(
                                                                          fontFamily:
                                                                              'Poppins',
                                                                          color:
                                                                              FlutterFlowTheme.of(context).accent1,
                                                                          fontSize:
                                                                              20.0,
                                                                        ),
                                                                  ),
                                                                ),
                                                                Text(
                                                                  'Previsão de chegada às ${functions.formatDateTimeString(FFAppState().routeSelected.expectedArrivalDt)}',
                                                                  style: FlutterFlowTheme.of(
                                                                          context)
                                                                      .bodyMedium
                                                                      .override(
                                                                        fontFamily:
                                                                            'Poppins',
                                                                        color: FlutterFlowTheme.of(context)
                                                                            .accent1,
                                                                        fontSize:
                                                                            8.0,
                                                                      ),
                                                                ),
                                                              ],
                                                            ),
                                                          ],
                                                        ),
                                                        if (FFAppState()
                                                            .routeSelected
                                                            .stops
                                                            .where((e) =>
                                                                e.isComplete)
                                                            .toList()
                                                            .isEmpty)
                                                          Padding(
                                                            padding:
                                                                const EdgeInsetsDirectional
                                                                    .fromSTEB(
                                                                    0.0,
                                                                    0.0,
                                                                    20.0,
                                                                    0.0),
                                                            child:
                                                                FFButtonWidget(
                                                              text:
                                                                  'Iniciar viagem',
                                                              onPressed:
                                                                  () async {
                                                                // Verificar configurações de bateria antes de iniciar a viagem
                                                                final batteryConfigured =
                                                                    await BatteryOptimizationService
                                                                        .isBatteryOptimizationDisabled();
                                                                if (!batteryConfigured) {
                                                                  // Mostrar dialog de configuração de bateria
                                                                  final shouldProceed =
                                                                      await _showBatteryConfigurationDialog();
                                                                  if (!shouldProceed) {
                                                                    return; // Usuário cancelou
                                                                  }
                                                                }

                                                                await _startTrip();
                                                              },
                                                              options:
                                                                  FFButtonOptions(
                                                                height: 48.0,
                                                                padding:
                                                                    const EdgeInsetsDirectional
                                                                        .fromSTEB(
                                                                        24.0,
                                                                        0.0,
                                                                        24.0,
                                                                        0.0),
                                                                iconPadding:
                                                                    const EdgeInsetsDirectional
                                                                        .fromSTEB(
                                                                        0.0,
                                                                        0.0,
                                                                        0.0,
                                                                        0.0),
                                                                color: FlutterFlowTheme.of(
                                                                        context)
                                                                    .primary,
                                                                textStyle: FlutterFlowTheme.of(
                                                                        context)
                                                                    .titleSmall
                                                                    .override(
                                                                      fontFamily:
                                                                          'Poppins',
                                                                      color: Colors
                                                                          .white,
                                                                    ),
                                                                elevation: 3.0,
                                                                borderSide:
                                                                    const BorderSide(
                                                                  color: Colors
                                                                      .transparent,
                                                                  width: 1.0,
                                                                ),
                                                                borderRadius:
                                                                    BorderRadius
                                                                        .circular(
                                                                            8.0),
                                                              ),
                                                            ),
                                                          ),
                                                      ],
                                                    ),
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                          Expanded(
                                            child: Container(
                                              height: 160.0,
                                              decoration: BoxDecoration(
                                                color:
                                                    FlutterFlowTheme.of(context)
                                                        .accent3,
                                                borderRadius:
                                                    BorderRadius.circular(8.0),
                                              ),
                                              child: Padding(
                                                padding:
                                                    const EdgeInsetsDirectional
                                                        .fromSTEB(
                                                        8.0, 0.0, 8.0, 0.0),
                                                child: Column(
                                                  mainAxisSize:
                                                      MainAxisSize.max,
                                                  children: [
                                                    Padding(
                                                      padding:
                                                          const EdgeInsetsDirectional
                                                              .fromSTEB(0.0,
                                                              8.0, 0.0, 0.0),
                                                      child: Text(
                                                        'Paradas',
                                                        style:
                                                            FlutterFlowTheme.of(
                                                                    context)
                                                                .bodyMedium
                                                                .override(
                                                                  fontFamily:
                                                                      'Poppins',
                                                                  color: FlutterFlowTheme.of(
                                                                          context)
                                                                      .secondary,
                                                                  fontSize:
                                                                      14.0,
                                                                ),
                                                      ),
                                                    ),
                                                    Expanded(
                                                      child: Stack(
                                                        children: [
                                                          Padding(
                                                            padding:
                                                                const EdgeInsetsDirectional
                                                                    .fromSTEB(
                                                                    8.0,
                                                                    0.0,
                                                                    0.0,
                                                                    0.0),
                                                            child: Container(
                                                              width: 2.0,
                                                              height: double
                                                                  .infinity,
                                                              decoration:
                                                                  BoxDecoration(
                                                                color: FlutterFlowTheme.of(
                                                                        context)
                                                                    .accent1,
                                                              ),
                                                            ),
                                                          ),
                                                          Builder(
                                                            builder: (context) {
                                                              final stops =
                                                                  FFAppState()
                                                                      .routeSelected
                                                                      .stops
                                                                      .toList();
                                                              return ListView
                                                                  .builder(
                                                                padding:
                                                                    EdgeInsets
                                                                        .zero,
                                                                shrinkWrap:
                                                                    true,
                                                                scrollDirection:
                                                                    Axis.vertical,
                                                                itemCount: stops
                                                                    .length,
                                                                itemBuilder:
                                                                    (context,
                                                                        stopsIndex) {
                                                                  final stopsItem =
                                                                      stops[
                                                                          stopsIndex];
                                                                  return Padding(
                                                                    padding: const EdgeInsetsDirectional
                                                                        .fromSTEB(
                                                                        0.0,
                                                                        8.0,
                                                                        0.0,
                                                                        0.0),
                                                                    child: Row(
                                                                      mainAxisSize:
                                                                          MainAxisSize
                                                                              .max,
                                                                      children: [
                                                                        Padding(
                                                                          padding: const EdgeInsetsDirectional
                                                                              .fromSTEB(
                                                                              0.0,
                                                                              0.0,
                                                                              8.0,
                                                                              0.0),
                                                                          child:
                                                                              Container(
                                                                            width:
                                                                                20.0,
                                                                            height:
                                                                                20.0,
                                                                            decoration:
                                                                                BoxDecoration(
                                                                              color: FlutterFlowTheme.of(context).accent1,
                                                                              borderRadius: BorderRadius.circular(24.0),
                                                                            ),
                                                                            child:
                                                                                Row(
                                                                              mainAxisSize: MainAxisSize.max,
                                                                              children: [
                                                                                if (stopsItem.isComplete)
                                                                                  Icon(
                                                                                    Icons.check_circle_rounded,
                                                                                    color: FlutterFlowTheme.of(context).tertiary,
                                                                                    size: 20.0,
                                                                                  ),
                                                                                if (!stopsItem.isComplete)
                                                                                  Icon(
                                                                                    Icons.watch_later_sharp,
                                                                                    color: FlutterFlowTheme.of(context).accent3,
                                                                                    size: 20.0,
                                                                                  ),
                                                                              ],
                                                                            ),
                                                                          ),
                                                                        ),
                                                                        Text(
                                                                          stopsItem
                                                                              .stopName,
                                                                          style:
                                                                              FlutterFlowTheme.of(context).bodyMedium,
                                                                        ),
                                                                      ],
                                                                    ),
                                                                  );
                                                                },
                                                              );
                                                            },
                                                          ),
                                                        ],
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            Padding(
                              padding: const EdgeInsetsDirectional.fromSTEB(
                                  0.0, 0.0, 0.0, 30.0),
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  if (FFAppState().stopInProgress.hasStopId() &&
                                      _model.menu)
                                    Align(
                                      child: Padding(
                                        padding: const EdgeInsetsDirectional
                                            .fromSTEB(0.0, 0.0, 0.0, 20.0),
                                        child: InkWell(
                                          splashColor: Colors.transparent,
                                          focusColor: Colors.transparent,
                                          hoverColor: Colors.transparent,
                                          highlightColor: Colors.transparent,
                                          onTap: () async {
                                            setState(() {
                                              _model.menu = false;
                                            });
                                          },
                                          child: Icon(
                                            Icons.keyboard_arrow_down_rounded,
                                            color: FlutterFlowTheme.of(context)
                                                .primary,
                                            size: 32.0,
                                          ),
                                        ),
                                      ),
                                    ),
                                  if (FFAppState().stopInProgress.hasStopId() &&
                                      !_model.menu)
                                    Align(
                                      child: Padding(
                                        padding: const EdgeInsetsDirectional
                                            .fromSTEB(0.0, 0.0, 0.0, 20.0),
                                        child: InkWell(
                                          splashColor: Colors.transparent,
                                          focusColor: Colors.transparent,
                                          hoverColor: Colors.transparent,
                                          highlightColor: Colors.transparent,
                                          onTap: () async {
                                            setState(() {
                                              _model.menu = true;
                                            });
                                          },
                                          child: Icon(
                                            Icons.keyboard_arrow_up_rounded,
                                            color: FlutterFlowTheme.of(context)
                                                .primary,
                                            size: 32.0,
                                          ),
                                        ),
                                      ),
                                    ),
                                  Padding(
                                    padding: const EdgeInsets.all(8.0),
                                    child: Text(
                                      'Dados não sincronizados: ${FFAppState().positions.length.toString()}',
                                      style: FlutterFlowTheme.of(context)
                                          .bodyMedium,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                    ],
                  ),
                ),
                if (hasLocationIssues)
                  Positioned.fill(
                    child: Container(
                      color: Colors.black54,
                      child: Center(
                        child: AlertDialog(
                          title: const Text('Problema de Localização'),
                          content: const Text(
                            'Não foi possível obter sua localização. '
                            'Verifique se o GPS está ativo e as permissões foram concedidas.',
                          ),
                          actions: [
                            TextButton(
                              onPressed: () async {
                                await _getLocation();
                              },
                              child: const Text('Tentar Novamente'),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            )),
      ),
    );
  }

  dynamic openWhatsAppChatWithCurrentCompany() async {
    await launchURL(
        'https://wa.me/55${FFAppState().routeSelected.companyPhone}?text=Ol%C3%A1%2C%20preciso%20de%20ajuda%20com%20meu%20aplicativo%20RotaSys');
  }

  void showConfirmConsentDialog(BuildContext context) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Termos de Uso e Política de Privacidade'),
          content: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Para utilizar este aplicativo, você deve aceitar nossos Termos de Uso e Política de Privacidade.',
                  style: TextStyle(fontSize: 16),
                ),
                const SizedBox(height: 16),
                const Text(
                  'Este aplicativo coleta dados de localização para permitir o rastreamento de rotas em tempo real, mesmo quando o aplicativo está fechado ou não está em uso.',
                  style: TextStyle(fontSize: 14),
                ),
                const SizedBox(height: 16),
                GestureDetector(
                  onTap: () async {
                    const url =
                        'https://www.pigmadesenvolvimentos.com.br/termos-de-uso';
                    if (await canLaunchUrl(Uri.parse(url))) {
                      await launchUrl(Uri.parse(url));
                    }
                  },
                  child: const Text(
                    'Leia os Termos de Uso completos',
                    style: TextStyle(
                      color: Colors.blue,
                      decoration: TextDecoration.underline,
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                GestureDetector(
                  onTap: () async {
                    const url =
                        'https://www.pigmadesenvolvimentos.com.br/politica-de-privacidade';
                    if (await canLaunchUrl(Uri.parse(url))) {
                      await launchUrl(Uri.parse(url));
                    }
                  },
                  child: const Text(
                    'Leia a Política de Privacidade completa',
                    style: TextStyle(
                      color: Colors.blue,
                      decoration: TextDecoration.underline,
                    ),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.of(context).pop();
                // Não aceitar os termos resulta em fechar o app
                SystemNavigator.pop();
              },
              child: const Text('Recusar'),
            ),
            TextButton(
              onPressed: () {
                setState(() {
                  FFAppState().acceptedTermsAndPrivacy = true;
                });
                Navigator.of(context).pop();
              },
              child: const Text('Aceitar'),
            ),
          ],
        );
      },
    );
  }

  void showRemoveConsentDialog(BuildContext bcontext) {
    showDialog(
      context: bcontext,
      builder: (bcontext) {
        return AlertDialog(
          title: Row(
              mainAxisSize: MainAxisSize.max,
              mainAxisAlignment: MainAxisAlignment.end,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                InkWell(
                  splashColor: Colors.transparent,
                  focusColor: Colors.transparent,
                  hoverColor: Colors.transparent,
                  highlightColor: Colors.transparent,
                  onTap: () {
                    Navigator.of(bcontext).pop();
                  },
                  child: const Icon(
                    Icons.close_rounded,
                    color: Color(0xFF2D2D6B),
                    size: 28.0,
                  ),
                ),
              ]),
          content: SingleChildScrollView(
            child: ListBody(
              children: <Widget>[
                RichText(
                    text: TextSpan(children: [
                  const TextSpan(
                    text: 'Ao remover a concordância com os',
                    style: TextStyle(color: Colors.black, fontSize: 16.0),
                  ),
                  TextSpan(
                    text: ' Termos de Uso ',
                    style: const TextStyle(
                        color: Colors.blue,
                        fontSize: 16.0,
                        fontWeight: FontWeight.bold),
                    recognizer: TapGestureRecognizer()
                      ..onTap = () {
                        launchUrl(Uri(
                            scheme: 'https',
                            host: '1drv.ms',
                            path: 'w/s!Ag-lHaRe-G-gguV-TkfoOYCqnIsSGw'));
                      },
                  ),
                  const TextSpan(
                    text: 'e com a',
                    style: TextStyle(color: Colors.black, fontSize: 16.0),
                  ),
                  TextSpan(
                    text: ' Política de Privacidade ',
                    style: const TextStyle(
                        color: Colors.blue,
                        fontSize: 16.0,
                        fontWeight: FontWeight.bold),
                    recognizer: TapGestureRecognizer()
                      ..onTap = () {
                        launchUrl(Uri(
                            scheme: 'https',
                            host: '1drv.ms',
                            path: 'w/s!Ag-lHaRe-G-gguZJMYQcMsih2pBJ8A'));
                      },
                  ),
                  const TextSpan(
                    text:
                        'você não poderá continuar utilizando este aplicativo. \n\nDeseja remover a concordância com as condições acima?',
                    style: TextStyle(color: Colors.black, fontSize: 16.0),
                  ),
                ])),
              ],
            ),
          ),
          actions: <Widget>[
            Row(
                mainAxisSize: MainAxisSize.max,
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsetsDirectional.fromSTEB(
                        16.0, 0.0, 16.0, 0.0),
                    child: FFButtonWidget(
                      onPressed: () async {
                        var termsAcceptance =
                            await APIsPigmanGroup.setTermsAcceptanceCall.call(
                          cpf: FFAppState().cpf,
                          termsAccepted: false,
                        );

                        if (!termsAcceptance.succeeded) {
                          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                            content: const Text(
                              'Houve um erro durante esta requisição. Tente novamente.',
                              style: TextStyle(
                                color: Colors.white,
                              ),
                            ),
                            duration: const Duration(milliseconds: 4000),
                            backgroundColor: FlutterFlowTheme.of(context).error,
                          ));
                        } else {
                          setState(() {
                            FFAppState().acceptedTermsAndPrivacy = false;
                            FFAppState().viagemDisponivel = RouteStruct();
                            FFAppState().cpf = '';
                            FFAppState().routeSelected = RouteStruct();
                          });

                          Navigator.of(context).pop(); // Close the dialog
                          context.pushReplacementNamed(
                              'codigoAcesso'); // Close the dialog
                        }
                      },
                      text: 'Remover concordância',
                      options: FFButtonOptions(
                        width: 250.0,
                        height: 50.0,
                        padding: const EdgeInsetsDirectional.fromSTEB(
                            16.0, 0.0, 16.0, 0.0),
                        iconPadding: const EdgeInsetsDirectional.fromSTEB(
                            0.0, 0.0, 0.0, 0.0),
                        color: FlutterFlowTheme.of(context).alternate,
                        textStyle:
                            FlutterFlowTheme.of(context).titleSmall.override(
                                  fontFamily: 'Poppins',
                                  color: Colors.white,
                                  fontSize: 14.0,
                                ),
                        elevation: 0.0,
                        borderSide: const BorderSide(
                          color: Color(0xFFBF3139),
                          width: 2.0,
                        ),
                        borderRadius: BorderRadius.circular(8.0),
                      ),
                    ),
                  )
                ]),
          ],
        );
      },
    );
  }
}
