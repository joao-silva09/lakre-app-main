import '/backend/api_requests/api_calls.dart';
import '/backend/backend.dart';
import '/flutter_flow/flutter_flow_theme.dart';
import '/flutter_flow/flutter_flow_util.dart';
import '/flutter_flow/flutter_flow_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:mask_text_input_formatter/mask_text_input_formatter.dart';
// REMOVIDO: import 'package:location/location.dart';
import 'package:geolocator/geolocator.dart'; // ADICIONADO: usar apenas geolocator
import 'codigo_acesso_model.dart';
export 'codigo_acesso_model.dart';

class CodigoAcessoWidget extends StatefulWidget {
  const CodigoAcessoWidget({super.key});

  @override
  State<CodigoAcessoWidget> createState() => _CodigoAcessoWidgetState();
}

class _CodigoAcessoWidgetState extends State<CodigoAcessoWidget> {
  late CodigoAcessoModel _model;

  final scaffoldKey = GlobalKey<ScaffoldState>();
  LatLng? currentUserLocationValue;
  bool hasLocationIssues = false;

  var maskFormatter = MaskTextInputFormatter(
    mask: '###.###.###-##',
    filter: {"#": RegExp(r'[0-9]')},
    type: MaskAutoCompletionType.lazy,
  );

  @override
  void initState() {
    super.initState();
    _model = createModel(context, () => CodigoAcessoModel());

    _model.textController ??= TextEditingController();
    _model.textFieldFocusNode ??= FocusNode();

    // On page load action.
    SchedulerBinding.instance.addPostFrameCallback((_) async {
      // MODIFICADO: usar o novo método _getLocation
      await _getLocation();

      if (FFAppState().cpf.isNotEmpty) {
        _model.getCurrentRoute = await APIsPigmanGroup.gETCurrentRouteCall.call(
          cpf: FFAppState().cpf,
        );

        if ((_model.getCurrentRoute?.succeeded ?? true)) {
          setState(() {
            FFAppState().routeSelected =
                APIsPigmanGroup.gETCurrentRouteCall.route(
              (_model.getCurrentRoute?.jsonBody ?? ''),
            )!;
          });

          if (FFAppState()
              .routeSelected
              .stops
              .where((e) => !e.isComplete)
              .toList()
              .isNotEmpty) {
            setState(() {
              FFAppState().stopInProgress = FFAppState()
                  .routeSelected
                  .stops
                  .where((e) => !e.isComplete)
                  .toList()
                  .first;
            });
          } else {
            setState(() {
              FFAppState().stopInProgress =
                  FFAppState().routeSelected.stops.last;
            });
          }

          context.pushReplacementNamed('home');
        } else {
          _model.getNextRoute = await APIsPigmanGroup.getNextRouteCall.call(
            cpf: FFAppState().cpf,
          );

          if ((_model.getNextRoute?.succeeded ?? true)) {
            setState(() {
              FFAppState().routeSelected =
                  APIsPigmanGroup.getNextRouteCall.rota(
                (_model.getNextRoute?.jsonBody ?? ''),
              )!;
            });

            setState(() {
              FFAppState().latLngDriver = currentUserLocationValue;
            });
          }

          context.pushReplacementNamed('home');
        }
      }

      setState(() {});
    });
  }

  @override
  void dispose() {
    _model.dispose();
    super.dispose();
  }

  /// NOVO: Método unificado para obter localização usando apenas Geolocator
  Future<void> _getLocation() async {
    try {
      debugPrint('📍 Iniciando obtenção de localização...');

      // Verificar se o serviço de localização está habilitado
      bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        debugPrint('❌ Serviço de localização não está habilitado');
        // Tentar solicitar que o usuário habilite
        serviceEnabled = await Geolocator.openLocationSettings();
        if (!serviceEnabled) {
          setState(() {
            hasLocationIssues = true;
          });
          return;
        }
      }

      // Verificar permissões
      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        debugPrint('🔍 Solicitando permissão de localização...');
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied) {
          debugPrint('❌ Permissão de localização negada');
          setState(() {
            hasLocationIssues = true;
          });
          return;
        }
      }

      if (permission == LocationPermission.deniedForever) {
        debugPrint('❌ Permissão de localização negada permanentemente');
        setState(() {
          hasLocationIssues = true;
        });
        return;
      }

      // Obter localização atual
      debugPrint('📡 Obtendo posição atual...');
      Position currentLocation = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          distanceFilter: 0,
        ),
      );

      setState(() {
        hasLocationIssues = false;
        currentUserLocationValue = LatLng(
          currentLocation.latitude,
          currentLocation.longitude,
        );
        FFAppState().latLngDriver = currentUserLocationValue;
      });

      debugPrint('✅ Localização obtida com sucesso: '
          'Lat=${currentLocation.latitude}, Lng=${currentLocation.longitude}');
    } catch (e) {
      debugPrint('❌ Erro ao obter localização: $e');
      setState(() {
        hasLocationIssues = true;
      });

      // Tentar obter última localização conhecida como fallback
      try {
        Position? lastKnownPosition = await Geolocator.getLastKnownPosition();
        if (lastKnownPosition != null) {
          setState(() {
            currentUserLocationValue = LatLng(
              lastKnownPosition.latitude,
              lastKnownPosition.longitude,
            );
            FFAppState().latLngDriver = currentUserLocationValue;
            hasLocationIssues = false;
          });
          debugPrint('📍 Usando última localização conhecida: '
              'Lat=${lastKnownPosition.latitude}, Lng=${lastKnownPosition.longitude}');
        }
      } catch (lastLocationError) {
        debugPrint(
            '❌ Erro ao obter última localização conhecida: $lastLocationError');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => _model.unfocusNode.canRequestFocus
          ? FocusScope.of(context).requestFocus(_model.unfocusNode)
          : FocusScope.of(context).unfocus(),
      child: Scaffold(
        key: scaffoldKey,
        backgroundColor: FlutterFlowTheme.of(context).primaryBackground,
        body: SafeArea(
          top: true,
          child: Stack(
            children: [
              Align(
                alignment: const AlignmentDirectional(0.0, 0.0),
                child: Container(
                  width: double.infinity,
                  height: double.infinity,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [
                        FlutterFlowTheme.of(context).primary,
                        FlutterFlowTheme.of(context).secondary
                      ],
                      stops: const [0.0, 1.0],
                      begin: const AlignmentDirectional(0.0, -1.0),
                      end: const AlignmentDirectional(0, 1.0),
                    ),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.max,
                    children: [
                      Expanded(
                        child: Container(
                          width: double.infinity,
                          height: 500.0,
                          decoration: const BoxDecoration(),
                          child: Column(
                            mainAxisSize: MainAxisSize.max,
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Padding(
                                padding: const EdgeInsetsDirectional.fromSTEB(
                                    0.0, 0.0, 0.0, 50.0),
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(8.0),
                                  child: Image.asset(
                                    'assets/images/rotasysAppIcon.png',
                                    width: 150.0,
                                    height: 150.0,
                                    fit: BoxFit.cover,
                                  ),
                                ),
                              ),
                              Padding(
                                padding: const EdgeInsetsDirectional.fromSTEB(
                                    44.0, 0.0, 44.0, 20.0),
                                child: Container(
                                  width: double.infinity,
                                  height: 60.0,
                                  decoration: BoxDecoration(
                                    color: FlutterFlowTheme.of(context)
                                        .secondaryBackground,
                                    boxShadow: const [
                                      BoxShadow(
                                        blurRadius: 5.0,
                                        color: Color(0x4D101213),
                                        offset: Offset(0.0, 2.0),
                                      )
                                    ],
                                    borderRadius: BorderRadius.circular(8.0),
                                  ),
                                  child: TextFormField(
                                    controller: _model.textController,
                                    focusNode: _model.textFieldFocusNode,
                                    inputFormatters: [maskFormatter],
                                    autofocus: true,
                                    obscureText: false,
                                    decoration: InputDecoration(
                                      labelText: 'Digite seu CPF',
                                      labelStyle: FlutterFlowTheme.of(context)
                                          .labelMedium
                                          .override(
                                            fontFamily: 'Nunito Sans',
                                            letterSpacing: 0.0,
                                          ),
                                      hintText: '000.000.000-00',
                                      hintStyle: FlutterFlowTheme.of(context)
                                          .labelMedium
                                          .override(
                                            fontFamily: 'Nunito Sans',
                                            letterSpacing: 0.0,
                                          ),
                                      enabledBorder: OutlineInputBorder(
                                        borderSide: const BorderSide(
                                          color: Color(0x00000000),
                                          width: 0.0,
                                        ),
                                        borderRadius:
                                            BorderRadius.circular(8.0),
                                      ),
                                      focusedBorder: OutlineInputBorder(
                                        borderSide: const BorderSide(
                                          color: Color(0x00000000),
                                          width: 0.0,
                                        ),
                                        borderRadius:
                                            BorderRadius.circular(8.0),
                                      ),
                                      errorBorder: OutlineInputBorder(
                                        borderSide: BorderSide(
                                          color: FlutterFlowTheme.of(context)
                                              .error,
                                          width: 0.0,
                                        ),
                                        borderRadius:
                                            BorderRadius.circular(8.0),
                                      ),
                                      focusedErrorBorder: OutlineInputBorder(
                                        borderSide: BorderSide(
                                          color: FlutterFlowTheme.of(context)
                                              .error,
                                          width: 0.0,
                                        ),
                                        borderRadius:
                                            BorderRadius.circular(8.0),
                                      ),
                                      filled: true,
                                      fillColor: FlutterFlowTheme.of(context)
                                          .secondaryBackground,
                                      contentPadding:
                                          const EdgeInsetsDirectional.fromSTEB(
                                              20.0, 24.0, 0.0, 24.0),
                                    ),
                                    style: FlutterFlowTheme.of(context)
                                        .bodyMedium
                                        .override(
                                          fontFamily: 'Nunito Sans',
                                          letterSpacing: 0.0,
                                        ),
                                    keyboardType: TextInputType.number,
                                    validator: _model.textControllerValidator
                                        .asValidator(context),
                                  ),
                                ),
                              ),
                              Padding(
                                padding: const EdgeInsetsDirectional.fromSTEB(
                                    44.0, 0.0, 44.0, 0.0),
                                child: FFButtonWidget(
                                  onPressed: () async {
                                    if (_model.formKey.currentState == null ||
                                        !_model.formKey.currentState!
                                            .validate()) {
                                      return;
                                    }

                                    // Verificar localização antes de prosseguir
                                    if (hasLocationIssues) {
                                      await _getLocation();
                                    }

                                    if (hasLocationIssues) {
                                      ScaffoldMessenger.of(context)
                                          .showSnackBar(
                                        SnackBar(
                                          content: const Text(
                                            'Não foi possível obter sua localização. '
                                            'Verifique se o GPS está ativo e as permissões foram concedidas.',
                                            style: TextStyle(
                                              color: Colors.white,
                                            ),
                                          ),
                                          duration: const Duration(seconds: 4),
                                          backgroundColor:
                                              FlutterFlowTheme.of(context)
                                                  .error,
                                        ),
                                      );
                                      return;
                                    }

                                    setState(() {
                                      FFAppState().cpf =
                                          maskFormatter.unmaskText(
                                              _model.textController.text);
                                    });

                                    _model.getCurrentRoute =
                                        await APIsPigmanGroup
                                            .gETCurrentRouteCall
                                            .call(
                                      cpf: FFAppState().cpf,
                                    );

                                    if ((_model.getCurrentRoute?.succeeded ??
                                        true)) {
                                      setState(() {
                                        FFAppState().routeSelected =
                                            APIsPigmanGroup.gETCurrentRouteCall
                                                .route(
                                          (_model.getCurrentRoute?.jsonBody ??
                                              ''),
                                        )!;
                                      });

                                      if (FFAppState()
                                          .routeSelected
                                          .stops
                                          .where((e) => !e.isComplete)
                                          .toList()
                                          .isNotEmpty) {
                                        setState(() {
                                          FFAppState().stopInProgress =
                                              FFAppState()
                                                  .routeSelected
                                                  .stops
                                                  .where((e) => !e.isComplete)
                                                  .toList()
                                                  .first;
                                        });
                                      } else {
                                        setState(() {
                                          FFAppState().stopInProgress =
                                              FFAppState()
                                                  .routeSelected
                                                  .stops
                                                  .last;
                                        });
                                      }

                                      context.pushReplacementNamed('home');
                                    } else {
                                      _model.getNextRoute =
                                          await APIsPigmanGroup.getNextRouteCall
                                              .call(
                                        cpf: FFAppState().cpf,
                                      );

                                      if ((_model.getNextRoute?.succeeded ??
                                          true)) {
                                        setState(() {
                                          FFAppState().routeSelected =
                                              APIsPigmanGroup.getNextRouteCall
                                                  .rota(
                                            (_model.getNextRoute?.jsonBody ??
                                                ''),
                                          )!;
                                        });

                                        setState(() {
                                          FFAppState().latLngDriver =
                                              currentUserLocationValue;
                                        });
                                      }

                                      context.pushReplacementNamed('home');
                                    }

                                    setState(() {});
                                  },
                                  text: 'Entrar',
                                  options: FFButtonOptions(
                                    width: double.infinity,
                                    height: 60.0,
                                    padding:
                                        const EdgeInsetsDirectional.fromSTEB(
                                            0.0, 0.0, 0.0, 0.0),
                                    iconPadding:
                                        const EdgeInsetsDirectional.fromSTEB(
                                            0.0, 0.0, 0.0, 0.0),
                                    color: const Color(0xFF101213),
                                    textStyle: FlutterFlowTheme.of(context)
                                        .titleMedium
                                        .override(
                                          fontFamily: 'Nunito Sans',
                                          color: Colors.white,
                                          letterSpacing: 0.0,
                                        ),
                                    elevation: 2.0,
                                    borderSide: const BorderSide(
                                      color: Colors.transparent,
                                      width: 1.0,
                                    ),
                                    borderRadius: BorderRadius.circular(8.0),
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
              ),

              // Indicador de problemas de localização
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
                          TextButton(
                            onPressed: () {
                              // Abrir configurações do sistema
                              Geolocator.openAppSettings();
                            },
                            child: const Text('Abrir Configurações'),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
