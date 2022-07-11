import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:typed_data/typed_data.dart' as typed;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';
import 'package:platform_device_id/platform_device_id.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({Key? key}) : super(key: key);

  // This widget is the root of your application.
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Flutter Demo',
      theme: ThemeData(
        primarySwatch: Colors.blue,
      ),
      home: const MyHomePage(title: 'Deslocamento Linear'),
    );
  }
}

class MyHomePage extends StatefulWidget {
  const MyHomePage({Key? key, required this.title}) : super(key: key);

  final String title;

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {

  final String broker = 'broker.hivemq.com';
  final int port = 1883;
  final String pubTopic = "Robotica.UEPG.Deslocamento.Linear/ESP_sub";
  final String subTopic = "Robotica.UEPG.Deslocamento.Linear/ESP_pub";

  late String clientIdentifier = "";
  late MqttServerClient client;
  late StreamSubscription subscription;
  TextEditingController speedController = TextEditingController();
  FocusNode speedFocus = FocusNode();

  bool _updateFromEsp = false;
  int _espDeslocamentoX = 0;
  int _espMaxStep = 0;
  int _espCalibracao = 0;
  int _espSpeed = -1;
  num _espPosition = 0;

  int speed = 25;
  int MAX_SPEED = 30;

  MqttConnectionState connectionState = MqttConnectionState.disconnected;
  double appCarroPos = 35;
  double appCarroMaxPos = 275;
  double appCarroMinPos = 35;

  double espCarroPos = 35;

  bool isLoading = false;

  @override
  void initState() {
    super.initState();
    _connect();
    _loadPrefs();
    speedFocus.addListener(() {
      if(!speedFocus.hasFocus){
        speedController.text = speed.toString();
      }
    });
    speedController.addListener(() {
      var txt = speedController.text;
      var d = double.tryParse(txt);
      if(txt.isNotEmpty && d is double && d >= 0 && d <= MAX_SPEED){
        setState(() => speed = d.floor());
      }
    });
  }

  void _loadPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    speed = prefs.getInt('speed') ?? MAX_SPEED ~/ 2;
    speedController.text = speed.toString();
  }

  Future<String> getPlatformId() async {
    var rng = Random();
    String random = rng.nextInt(1 << 30).toString();
    try {
      await PlatformDeviceId.getDeviceId ?? random;
    } catch (ex) {
      //ignore
    }
    return random;
  }

  void _connect() async {
    String identifier = await getPlatformId();
    setState(() {
      clientIdentifier = identifier;
    });

    client = MqttServerClient(broker, clientIdentifier);
    client.port = port;
    client.autoReconnect = true;
    client.resubscribeOnAutoReconnect = true;
    client.onConnected = _onConnected;
    client.onAutoReconnected = _onConnected;
    client.onDisconnected = _onDisconnected;
    client.onAutoReconnect = _onDisconnected;

    try {
      await client.connect();
    } catch (e) {
      print(e);
      _disconnect();
    }
    client.subscribe(subTopic, MqttQos.exactlyOnce);
    subscription = client.updates?.listen(_onMessage) as StreamSubscription;
  }

  void _publishMessage(String message){
    if(client.connectionState == MqttConnectionState.connected){
      final payload = MqttClientPayloadBuilder().addString(message).payload;
      if(payload is typed.Uint8Buffer) {
        print("Publish Message in $pubTopic: $message");
        client.publishMessage(pubTopic, MqttQos.atMostOnce, payload);
      }
    }
  }

  void _disconnect() {
    print('[MQTT client] _disconnect()');
    client.disconnect();
    _onDisconnected();
  }

  void _onConnected() {
    setState(() {
      if (client.connectionStatus != null && connectionState != client.connectionStatus!.state) {
        _updateFromEsp = true;
        print('[MQTT client] $connectionState -> Connected');
        connectionState = client.connectionStatus!.state;
      }
    });
  }

  void _onDisconnected() {
    setState(() {
      if (client.connectionStatus != null && connectionState != client.connectionStatus!.state) {
        connectionState = client.connectionStatus!.state;
        print('[MQTT client] Not Connected: $connectionState');
      }
    });
  }

  void _onMessage(List<MqttReceivedMessage> event) {
    print(event.length);
    final MqttPublishMessage recMess = event[0].payload as MqttPublishMessage;
    final String message =
    MqttPublishPayload.bytesToStringAsString(recMess.payload.message);

    print('[MQTT client] MQTT message: topic is <${event[0].topic}>, '
        'payload is <-- ${message} -->');
    try {
      Map<String, dynamic> data = jsonDecode(message);

      setState(() {
        if(_updateFromEsp || _espDeslocamentoX != data["deslocamentoX"]){
          _espDeslocamentoX = data["deslocamentoX"] ?? 0;
          final proportion = _espMaxStep == 0 ? 0 : (appCarroMaxPos - appCarroMinPos) / _espMaxStep;
          appCarroPos = min(appCarroMinPos + _espDeslocamentoX * proportion, appCarroMaxPos);
        }
        if(_updateFromEsp || _espPosition != data["position"] || _espMaxStep != data["maxStep"]){
          _espPosition = data["position"] ?? 0;
          _espMaxStep = data["maxStep"] ?? 0;
          _updatePosicao();
        }
        _espCalibracao = data["calibracao_stage"] ?? 0;
        if(_updateFromEsp || _espSpeed != data["speed"]){
          speed = _espSpeed = data["speed"] ?? 0;
          speedController.text = speed.toString();
        }
      });
    } catch (ex) {
      print(ex.toString());
      // ignore
    }
  }

  @override
  Widget build(BuildContext context) {
    final loading = ValueNotifier<bool>(false);
    final carro = Image(
      image: AssetImage('assets/carro1.png'),
      width: 75,
    );
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
      ),
      body: Column(
          children: [
            SizedBox(
              width: MediaQuery
                  .of(context)
                  .size
                  .width,
              child: Container(
                alignment: Alignment.center,
                decoration: BoxDecoration(
                    color: connectionState == MqttConnectionState.connected
                        ? Colors.green.withOpacity(0.5)
                        : Colors.redAccent.withOpacity(0.5)
                ),
                child: Text(
                  connectionState == MqttConnectionState.connected
                      ? 'Conectado'
                      : 'Desconectado',
                ),
              ),
            ),
            SingleChildScrollView(
              child: Column(
                children: [
                  Text(
                    '$_espDeslocamentoX mm',
                    style: Theme
                        .of(context)
                        .textTheme
                        .headline4,
                  ),
                  ClipRRect(
                      child: Container(
                        child: Stack(
                          children: [
                            Positioned(
                              child:
                              Image(
                                image: AssetImage('assets/atuador1.png'),
                                width: 75,
                              ),
                            ),Positioned(
                              top: espCarroPos,
                              child:
                              Opacity(
                                  opacity: 0.5,
                                  child:Image(
                                    image: AssetImage('assets/carro1.png'),
                                    width: 75,
                                ),
                              ),
                            ),
                            Positioned(
                              top: appCarroPos,
                              child:Draggable(
                                axis: Axis.vertical,
                                onDragUpdate: (d){
                                  setState(() =>
                                    appCarroPos = min(max(appCarroPos+d.delta.dy,appCarroMinPos),appCarroMaxPos));
                                },
                                onDragEnd: _mqttSendPosition,
                                feedback: Container(),
                                child: carro,
                              ),
                            ),
                          ],
                        ),
                      )
                  ),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        flex: 4,
                        child: Padding(
                          padding: EdgeInsets.only(left: 20, top: 16),
                          child: TextFormField(
                            controller: speedController,
                            autovalidateMode: AutovalidateMode
                                .onUserInteraction,
                            validator: (newValue) {
                              var d = int.tryParse(newValue ?? "") ?? -1;
                              return d < 0 || d > MAX_SPEED
                                  ? "A velocidade deve estar entre 0 e $MAX_SPEED"
                                  : null;
                            },
                            focusNode: speedFocus,
                            decoration: InputDecoration(
                                border: OutlineInputBorder(),
                                labelText: 'Velocidade',
                                errorMaxLines: 2,
                                errorStyle: TextStyle(
                                  fontSize: Theme
                                      .of(context)
                                      .textTheme
                                      .labelSmall
                                      ?.fontSize ?? 10,
                                )
                            ),
                            inputFormatters: [
                              FilteringTextInputFormatter.digitsOnly
                            ],
                            keyboardType: TextInputType.number,
                          ),
                        ),
                      ),
                      Expanded(
                        flex: 6,
                        child: Padding(
                          padding: EdgeInsets.only(top: 20),
                          child:
                          Slider(
                            value: speed.toDouble(),
                            max: MAX_SPEED.toDouble(),
                            min: 0,
                            divisions: MAX_SPEED,
                            onChanged: _changeSpeed,
                          ),
                        ),
                      ),
                      Expanded(
                        flex: 2,
                        child: Padding(
                          padding: EdgeInsets.only(right: 10, top: 20),
                          child:
                          ElevatedButton(
                            onPressed: _espSpeed != speed
                                ? _mqttSendSpeed
                                : null,
                            child: const Text('OK'),
                            style: ButtonStyle(
                                  elevation: MaterialStateProperty.resolveWith<double>(
                                        (Set<MaterialState> states) {
                                      if (states.contains(MaterialState.pressed)
                                          ||  states.contains(MaterialState.disabled)) {
                                        return 0;
                                      }
                                      return 10;
                                    },
                                  )
                              )
                          ),
                        ),
                      ),
                    ],
                  ),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                          flex: 2,
                          child: Padding(
                              padding: EdgeInsets.only(right: 20, top: 40, left: 100),
                              child:
                              ElevatedButton.icon(
                                  icon: Icon(Icons.arrow_back_rounded),
                                  label: Text(""),
                                  onPressed: _mqttSendLeft,
                                  style: ButtonStyle(
                                      elevation: MaterialStateProperty.resolveWith<double>(
                                            (Set<MaterialState> states) {
                                          if (states.contains(MaterialState.pressed)
                                              ||  states.contains(MaterialState.disabled)) {
                                            return 0;
                                          }
                                          return 10;
                                        },
                                      )
                                  )
                              ),
                          )
                      ),
                      Expanded(
                          flex: 2,
                          child: Padding(
                            padding: EdgeInsets.only(top: 40),
                            child:
                            ElevatedButton.icon(
                                icon: Icon(Icons.home_filled),
                                label: Text("Home"),
                                onPressed: _mqttSendHome,
                                style: ButtonStyle(
                                    elevation: MaterialStateProperty.resolveWith<double>(
                                          (Set<MaterialState> states) {
                                        if (states.contains(MaterialState.pressed)
                                            ||  states.contains(MaterialState.disabled)) {
                                          return 0;
                                        }
                                        return 10;
                                      },
                                    )
                                )
                            ),
                          )
                      ),
                      Expanded(
                          flex: 2,
                          child: Padding(
                            padding: EdgeInsets.only(right: 100, top: 40, left: 20),
                            child:
                            ElevatedButton.icon(
                                icon: Icon(Icons.arrow_forward_rounded),
                                label: Text(""),
                                onPressed: _mqttSendRight,
                                style: ButtonStyle(
                                    elevation: MaterialStateProperty.resolveWith<double>(
                                          (Set<MaterialState> states) {
                                        if (states.contains(MaterialState.pressed)
                                            ||  states.contains(MaterialState.disabled)) {
                                          return 0;
                                        }
                                        return 10;
                                      },
                                    )
                                )
                            ),
                          )
                      ),
                ],
              ),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                          flex: 2,
                          child: Padding(
                            padding: EdgeInsets.only(right: 100, top: 30, left: 100),
                            child:
                            ElevatedButton(
                                child: isLoading
                                    ? Row(
                                        mainAxisAlignment: MainAxisAlignment.center,
                                        children: [
                                          CircularProgressIndicator(color: Colors.white,),
                                          const SizedBox(width: 24,),
                                          Text('Calibrando...')],
                                    )
                                    : Text('Calibrar'),
                                onPressed: () async {
                                  if(isLoading){
                                    return;
                                  }

                                  setState(() => isLoading = true);
                                  _mqttSendCalibration();
                                  await Future.delayed(Duration(seconds: 2));
                                  setState(() => isLoading = false);
                                },//() => loading.value = !loading.value,//_mqttSendCalibration,
                                style: ButtonStyle(
                                    elevation: MaterialStateProperty.resolveWith<double>(
                                          (Set<MaterialState> states) {
                                        if (states.contains(MaterialState.pressed)
                                            ||  states.contains(MaterialState.disabled)) {
                                          return 0;
                                        }
                                        return 10;
                                      },
                                    )
                                )
                            ),
                          )
                      ),
                    ],
                  )
            ]),
          )],
      ),
    );
  }

  void _mqttSendSpeed(){
    _publishMessage("s$speed");
  }

  void _mqttSendPosition(DraggableDetails d){
    final int pos = (_espMaxStep*(appCarroPos-appCarroMinPos)/(appCarroMaxPos-appCarroMinPos)).floor();
    _publishMessage("x$pos");
    print("Change position $pos");
  }

  void _changeSpeed(double value) {
    print("Change speed $value");
    if(speed != value.floor()) {
      setState(() => speed = value.floor());
      speedController.text = speed.toString();
    }
  }

  void _updatePosicao() {
    if(_espPosition < 0){
      espCarroPos = appCarroMinPos;
    }
    final proportion = _espMaxStep == 0 ? 0 : (appCarroMaxPos - appCarroMinPos) / _espMaxStep;
    espCarroPos = min(appCarroMinPos + _espPosition * proportion, appCarroMaxPos);
  }

  void _mqttSendCalibration(){
    print("Calibrando dispositivo");

    _publishMessage("c");
  }

  void _mqttSendLeft(){
    print("Movimentando para esquerda");

    //_espPosition  _espMaxStep
    if(_espDeslocamentoX < _espMaxStep){

      int dist_atual = _espDeslocamentoX;
      int dist_final = dist_atual+100;

      _publishMessage("x$dist_final");
    }
  }

  void _mqttSendRight(){
    print("Movimentando para direita");

    if(_espDeslocamentoX > appCarroMinPos){

      int dist_atual = _espDeslocamentoX;
      int dist_final = dist_atual-100;

      _publishMessage("x$dist_final");
    }
  }

  void _mqttSendHome(){
    print("Movimentando para Home (x = 0)");

    //deslocamentoX = 0
    _publishMessage("h");
  }

}
