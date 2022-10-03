import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:math';
import 'dart:ui' as ui;

import 'package:animated_flip_counter/animated_flip_counter.dart';
import 'package:community_material_icon/community_material_icon.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:pinput/pinput.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:swipable_stack/swipable_stack.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

const String argosServer = 'argos.nhcham.org';
const int cardWidth = 1024;
const int cardHeight = 512;
const int heartBeatDelay = 20;
Size cardSize = Size(cardWidth.toDouble(), cardHeight.toDouble());
double cardScale = 1.0;
double? cardScreenHeight;
String appVersion = "";
String appBuildNumber = "";

class NotifyingPageView extends StatefulWidget {
  final ValueNotifier<double> notifier;
  PageController controller;
  ScrollPhysics physics;

  List<Widget> children = [];

  NotifyingPageView(
      {Key? key,
      required this.notifier,
      required this.controller,
      this.physics = const PageScrollPhysics(),
      required this.children})
      : super(key: key);

  @override
  _NotifyingPageViewState createState() => _NotifyingPageViewState();
}

class _NotifyingPageViewState extends State<NotifyingPageView> {
  void _onScroll() {
    widget.notifier.value = widget.controller.page!;
  }

  @override
  void initState() {
    widget.controller.addListener(_onScroll);
    super.initState();
  }

  @override
  Widget build(BuildContext context) {
    return PageView(
      controller: widget.controller,
      physics: widget.physics,
      children: widget.children,
    );
  }
}

class AppScrollBehavior extends MaterialScrollBehavior {
  @override
  Set<PointerDeviceKind> get dragDevices => {
        PointerDeviceKind.touch,
        PointerDeviceKind.mouse,
        PointerDeviceKind.trackpad,
      };
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  PackageInfo.fromPlatform().then((packageInfo) {
    appVersion = packageInfo.version;
    appBuildNumber = packageInfo.buildNumber;

    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]).then((value) => runApp(const ArgosApp()));
  });
}

class Line {
  Color color;
  double lineWidth;
  bool clearMode;
  List<Offset> points = [];
  Line({required this.color, required this.lineWidth, required this.clearMode});
}

class Drawing {
  List<Line> lines = [];
}

class ArgosPainter extends CustomPainter {
  Drawing drawing;
  ui.Image? image;

  ArgosPainter({required this.drawing, this.image});

  @override
  void paint(Canvas canvas, Size size) {
    cardScale = size.height / cardHeight;
    cardScreenHeight ??= size.height;
    if (image != null) canvas.drawImage(image!, Offset.zero, Paint());
    double scale = (image == null) ? cardScale : 1.0;
    for (final line in drawing.lines) {
      double lineWidth = line.lineWidth / 100 * size.height;
      if (line.clearMode) {
        lineWidth *= 10;
      }
      Paint paint = Paint()
        ..strokeWidth = lineWidth
        ..strokeCap = StrokeCap.round
        ..color = line.color;
      if (line.clearMode) {
        if (image == null) {
          paint.color = const Color.fromARGB(255, 255, 128, 128);
        } else {
          paint.blendMode = BlendMode.clear;
        }
      }
      for (int i = 0; i < line.points.length - 1; i++) {
        canvas.drawLine(
            line.points[i] * scale, line.points[i + 1] * scale, paint);
      }
    }
  }

  @override
  bool shouldRepaint(ArgosPainter oldDelegate) {
    return true;
  }
}

class ArgosApp extends StatelessWidget {
  const ArgosApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Argos',
      theme: ThemeData(primarySwatch: Colors.blue, fontFamily: 'AlegreyaSans'),
      scrollBehavior: AppScrollBehavior(),
      home: const ArgosPage(),
    );
  }
}

class ArgosPage extends StatefulWidget {
  const ArgosPage({super.key});

  @override
  State<ArgosPage> createState() => _ArgosPageState();
}

enum Mode { none, host, display, participant }

class SlimButton extends StatelessWidget {
  final String label;
  final double fontSize;
  final void Function()? onPressed;

  const SlimButton(
      {super.key, required this.label, required this.fontSize, this.onPressed});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: fontSize * 0.2),
      child: Container(
          decoration: BoxDecoration(
              color: onPressed == null
                  ? const Color(0x80ffffff)
                  : const Color(0x80000000),
              borderRadius: BorderRadius.all(Radius.circular(fontSize * 0.3))),
          child: InkWell(
            onTap: onPressed,
            child: Padding(
              padding: EdgeInsets.symmetric(
                  horizontal: fontSize, vertical: fontSize * 0.5),
              child: Text(label,
                  style: TextStyle(
                      color: onPressed == null ? Colors.black : Colors.white,
                      fontSize: fontSize * 0.8,
                      fontWeight: onPressed == null
                          ? FontWeight.normal
                          : FontWeight.bold)),
            ),
          )),
    );
  }
}

class _ArgosPageState extends State<ArgosPage> with TickerProviderStateMixin {
  Drawing drawing = Drawing();
  WebSocketChannel? ws;
  ui.Image? image;
  bool clearMode = false;
  Mode mode = Mode.none;
  String? displayPin;
  String? participantPin;
  final TextEditingController pinController = TextEditingController();
  bool wrongPin = false;

  int displayCount = 0;
  int participantCount = 0;
  int nonRejectedSubmissionCount = 0;
  int rejectCount = 0;
  int acceptCount = 0;
  int discussCount = 0;
  int shownCardIndex = -1;
  List<int> discussList = [];
  List<int> acceptList = [];
  List<Image> submissions = [];
  SwipableStackController? _controller;
  bool canSwipePage = true;
  late AnimationController hostCardAnimationController;
  late AnimationController participantCardAnimationController;

  bool taskRunning = false;
  bool sentCard = false;
  String? sentCardReaction;

  int? showIndex;
  String? showPng;

  bool showExampleImage = false;

  final PageController _pageController = PageController(initialPage: 1);
  ValueNotifier<double> _pageNotifier = ValueNotifier<double>(0);

  void _listenController() {
    setState(() {});
  }

  @override
  void initState() {
    super.initState();
    _controller = SwipableStackController()..addListener(_listenController);
    hostCardAnimationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );
    participantCardAnimationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );

    // launch websocket heartbeat ping
    Random rng = Random();
    Timer(Duration(seconds: rng.nextInt(heartBeatDelay)), () {
      if (ws != null) {
        ws!.sink.add('{"command": "ping"}');
      }
      Timer.periodic(const Duration(seconds: heartBeatDelay), (timer) {
        if (ws != null) {
          ws!.sink.add('{"command": "ping"}');
        }
      });
    });

    tryRejoin();
  }

  void tryRejoin() async {
    final prefs = await SharedPreferences.getInstance();
    String? sid = prefs.getString('sid');
    if (sid != null) {
      final response =
          await http.get(Uri.parse('https://$argosServer/api/sid/$sid'));
      if (response.statusCode == 200) {
        connect({'command': 'sid', 'sid': sid});
      } else {
        await prefs.remove('sid');
      }
    }
  }

  @override
  void dispose() {
    _controller!.removeListener(_listenController);
    _controller!.dispose();
    _pageController.dispose();
    hostCardAnimationController.dispose();
    participantCardAnimationController.dispose();
    _pageNotifier.dispose();
    super.dispose();
  }

  void connect(var sendData) {
    ws = WebSocketChannel.connect(
      Uri.parse('wss://$argosServer/ws'),
    );
    ws!.sink.add('{"hello": "world"}');
    JsonEncoder encoder = const JsonEncoder();
    ws!.sink.add(encoder.convert(sendData));
    ws!.stream.listen((message) {
      JsonDecoder decoder = const JsonDecoder();
      var data = decoder.convert(message);
      if (data['status'] == 'welcome') {
        developer.log("AYYYY");
      }
      if (data['command'] == 'become_host') {
        developer.log(data.toString());
        wrongPin = false;
        displayPin = data['display_pin'];
        participantPin = data['participant_pin'];
        displayCount = 0;
        participantCount = 0;
        submissions = [];
        setState(() {
          mode = Mode.host;
          hostCardAnimationController.reset();
        });
        SharedPreferences.getInstance().then((prefs) {
          prefs.setString('sid', data['sid']);
        });
      } else if (data['command'] == 'rejoin_with_sid') {
        developer.log(data.toString());
        displayPin = data['display_pin'];
        participantPin = data['participant_pin'];
        displayCount = data['display_count'];
        participantCount = data['participant_count'];
        nonRejectedSubmissionCount = data['non_rejected_submissions'];
        taskRunning = data['task_running'];

        rejectCount = 0;
        acceptCount = 0;
        discussCount = 0;
        shownCardIndex = -1;
        ws!.sink.add('{"command": "show", "index": null}');

        acceptList.clear();
        discussList.clear();
        submissions.clear();

        for (String base64 in (data['base64_list'] ?? [])) {
          submissions.add(Image.memory(
            base64Decode(base64),
            fit: BoxFit.cover,
          ));
        }
        setState(() {
          mode = Mode.host;
        });
      } else if (data['command'] == 'become_display') {
        participantPin = data['participant_pin'];
        displayCount = 0;
        participantCount = 0;
        submissions = [];
        setState(() {
          mode = Mode.display;
        });
      } else if (data['command'] == 'become_participant') {
        setState(() {
          taskRunning = false;
          sentCard = false;
          sentCardReaction = null;
          clearImage();
          mode = Mode.participant;
        });
      } else if (data['command'] == 'wrong_pin') {
        wrongPin = true;
        pinController.clear();
        disconnect();
      } else if (data['command'] == 'update_game_stats') {
        setState(() {
          if (displayCount == 0 && data['display_count'] != 0) {
            hostCardAnimationController
                .animateTo(1.0, curve: Curves.easeInOut)
                .then((x) {
              displayCount = data['display_count'];
            });
          } else if (displayCount != 0 && data['display_count'] == 0) {
            displayCount = data['display_count'];
            hostCardAnimationController
                .animateTo(0.0, curve: Curves.easeInOut)
                .then((x) {});
          } else {
            displayCount = data['display_count'];
          }

          participantCount = data['participant_count'];
          nonRejectedSubmissionCount = data['non_rejected_submissions'];
          taskRunning = data['task_running'];
          showIndex = data['show_index'];
          showPng = (showIndex == null) ? null : data['show_png'];
        });
      } else if (data['command'] == 'submission') {
        setState(() {
          submissions.add(Image.memory(base64Decode(data['base64'])));
        });
      } else if (data['command'] == 'new_task') {
        setState(() {
          clearMode = false;
          hostCardAnimationController.reset();
          participantCardAnimationController.reset();
          sentCard = false;
          sentCardReaction = null;
          clearImage();
          taskRunning = true;
        });
      } else if (data['command'] == 'react') {
        setState(() {
          sentCardReaction = data['reaction'];
          if (sentCardReaction == 'reject') {
            clearMode = false;
            sentCard = false;
            taskRunning = true;
            participantCardAnimationController.animateTo(0.0,
                curve: Curves.easeInOut);
          }
        });
      }
    }, onDone: () {
      developer.log("websocket has closed!");
      disconnect();
    }, onError: (error) {
      developer.log("onError! $error");
      disconnect();
    });
  }

  void disconnect() {
    if (ws != null) {
      ws!.sink.close();
    }
    pinController.clear();
    ws = null;
    setState(() {
      mode = Mode.none;
      taskRunning = false;
    });
  }

  void updateImage() async {
    ui.PictureRecorder recorder = ui.PictureRecorder();
    Canvas canvas = Canvas(recorder);
    var painter = ArgosPainter(drawing: drawing, image: image);
    painter.paint(canvas, cardSize);
    image = await recorder.endRecording().toImage(cardWidth, cardHeight);

    drawing.lines = [];
    setState(() {});
  }

  void clearImage() async {
    ui.PictureRecorder recorder = ui.PictureRecorder();
    // ignore: unused_local_variable
    Canvas canvas = Canvas(recorder);
    image = await recorder.endRecording().toImage(cardWidth, cardHeight);
    drawing.lines = [];
    setState(() {});
  }

  void sendImage() async {
    ByteData? pngBytes =
        await image!.toByteData(format: ui.ImageByteFormat.png);
    if (pngBytes != null) {
      List<int> bytes = [];
      for (int i = 0; i < pngBytes.lengthInBytes; i++) {
        bytes.add(pngBytes.getUint8(i));
      }
      ws!.sink.add('{"command": "png", "png": "${base64.encode(bytes)}"}');
      setState(() {
        sentCard = true;
      });
    }
  }

  BoxDecoration getBackground(context) {
    return const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color(0xffaed1ef),
            Color(0xfffcc44b),
            Color(0xfff0b9ef),
          ],
        ),
        image: DecorationImage(
            image: AssetImage('data/bg.png'),
            opacity: 0.5,
            fit: BoxFit.cover,
            alignment: Alignment.bottomCenter));
  }

  @override
  Widget build(BuildContext context) {
    double width = MediaQuery.of(context).size.width;
    double shift = width / 16;
    double scale = (9 / 8) * 1.03;
    return Material(child: LayoutBuilder(builder: (context, constraints) {
      double fontSize = 14 / 600 * constraints.maxWidth;
      Widget child = Container();
      if (mode == Mode.host) {
        child = buildModeHost(context, fontSize);
      } else if (mode == Mode.display) {
        child = buildModeDisplay(context, fontSize);
      } else if (mode == Mode.participant) {
        child = buildModeParticipant(context, fontSize);
      } else {
        child = buildModeNone(context, fontSize);
      }

      return (mode == Mode.host)
          ? Stack(
              children: [
                LayoutBuilder(
                  builder: (context, constraints) {
                    return AnimatedBuilder(
                      animation: _pageNotifier,
                      builder: (context, widget) {
                        return Transform.scale(
                          scale: scale,
                          child: Transform.translate(
                              offset:
                                  Offset(-(_pageNotifier.value - 1) * shift, 0),
                              child: Container(
                                  decoration: getBackground(context))),
                        );
                      },
                    );
                  },
                ),
                child,
                if (displayCount == 0)
                  AnimatedBuilder(
                      animation: hostCardAnimationController,
                      builder: (context, widget) {
                        return Opacity(
                          opacity: 1 - hostCardAnimationController.value,
                          child: Transform.translate(
                            offset: Offset(
                                0,
                                -hostCardAnimationController.value *
                                    fontSize *
                                    10),
                            child: Align(
                              alignment: Alignment.topCenter,
                              child: Padding(
                                padding: EdgeInsets.only(top: fontSize * 2),
                                child: Card(
                                  elevation: 10,
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Padding(
                                        padding: EdgeInsets.fromLTRB(
                                            fontSize, fontSize, fontSize, 0),
                                        child: Text(
                                            'Bitte verbinde das Display!',
                                            style: TextStyle(
                                                fontSize: fontSize * 1.2)),
                                      ),
                                      Padding(
                                        padding: EdgeInsets.fromLTRB(
                                            fontSize, 0, fontSize, fontSize),
                                        child: Column(
                                          children: [
                                            Padding(
                                              padding: EdgeInsets.all(fontSize),
                                              child: Row(
                                                mainAxisSize: MainAxisSize.min,
                                                children: [
                                                  Text(
                                                    'Display PIN: ',
                                                    style: TextStyle(
                                                        fontSize:
                                                            fontSize * 1.2),
                                                  ),
                                                  Text(
                                                    '$displayPin',
                                                    style: TextStyle(
                                                        fontSize:
                                                            fontSize * 1.2,
                                                        fontWeight:
                                                            FontWeight.bold),
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
                        );
                      }),
              ],
            )
          : Stack(
              children: [
                Transform.scale(
                  scale: scale,
                  child: Container(
                    decoration: getBackground(context),
                  ),
                ),
                SafeArea(
                    child: Padding(
                        padding: EdgeInsets.all(fontSize / 2),
                        child: Container(child: child))),
              ],
            );
    }));
  }

  Widget buildModeNone(BuildContext context, double fontSize) {
    return Stack(
      children: [
        SizedBox.expand(
          child: Column(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Padding(
                  padding: EdgeInsets.only(top: fontSize),
                  child: Card(
                    elevation: 10,
                    child: Padding(
                      padding:
                          EdgeInsets.fromLTRB(fontSize, 0, fontSize, fontSize),
                      child: Column(
                        children: [
                          Padding(
                            padding: EdgeInsets.all(fontSize),
                            child: Text(
                              'Bitte gib die PIN ein:',
                              style: TextStyle(fontSize: fontSize * 1.2),
                            ),
                          ),
                          Pinput(
                            controller: pinController,
                            onCompleted: (pin) {
                              wrongPin = false;
                              connect({'command': 'pin', 'pin': pin});
                            },
                            keyboardType: TextInputType.number,
                            pinAnimationType: PinAnimationType.scale,
                            defaultPinTheme: PinTheme(
                              width: fontSize * 2,
                              height: fontSize * 2,
                              margin: EdgeInsets.all(fontSize * 0.2),
                              textStyle: TextStyle(
                                fontSize: fontSize,
                              ),
                              decoration: BoxDecoration(
                                color: const Color(0x10000000),
                                border: Border.all(
                                  color: const Color(0x20000000),
                                  width: fontSize * 0.05,
                                ),
                                borderRadius: BorderRadius.circular(500),
                              ),
                            ),
                            length: 4,
                          ),
                          if (wrongPin)
                            Padding(
                              padding: EdgeInsets.only(top: fontSize / 2),
                              child: Text("Die eingegebene PIN ist ungültig.",
                                  style: TextStyle(
                                      color: Colors.red,
                                      fontSize: fontSize * 0.8)),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
                SlimButton(
                    label: 'Eigenes Quiz starten',
                    fontSize: fontSize,
                    onPressed: () {
                      connect({'command': 'new'});
                      // ws!.sink.add('{"command": "new"}');
                    }),
              ]),
        ),
        Align(
            alignment: Alignment.bottomRight,
            child: InkWell(
              onTap: () {
                showModalBottomSheet(
                    context: context,
                    builder: (context) {
                      return ListView(
                        children: [
                          Padding(
                            padding: EdgeInsets.all(fontSize * 0.5),
                            child: MarkdownBody(
                                onTapLink: (text, href, title) {
                                  if (href != null) {
                                    launchUrl(Uri.parse(href));
                                  }
                                },
                                styleSheet: MarkdownStyleSheet(
                                    p: TextStyle(fontSize: fontSize * 0.8),
                                    h1: TextStyle(fontSize: fontSize * 1.2),
                                    h2: TextStyle(fontSize: fontSize * 1.0)),
                                data:
                                    '# Argos\n\nVersion: $appVersion+$appBuildNumber  \nProgrammierung: Dr. Michael Specht\n\n## Quelltext\n\n[https://github.com/specht/argos](https://github.com/specht/argos)  \n[https://github.com/specht/argos-server](https://github.com/specht/argos-server)\n\n## Verwendetes Material\n\nApp-Icon von [AndreaCharlesta](https://www.freepik.com/free-vector/butterfly-logo-colorful-gradient-illustrations_31557352.htm) / Freepik  \nHintergrundbild von [rawpixel.com](https://www.freepik.com/free-vector/education-pattern-background-doodle-style_16332411.htm) / Freepik  \nKartenhintergrund von [kues1](https://www.freepik.com/free-photo/white-paper-texture_1012270.htm) / Freepik'),
                          ),
                        ],
                      );
                    });
              },
              child: Container(
                decoration: BoxDecoration(
                  color: const Color(0x40000000),
                  borderRadius: BorderRadius.circular(fontSize),
                ),
                child: Padding(
                  padding: EdgeInsets.all(fontSize * 0.3),
                  child: Icon(
                    Icons.info_outline,
                    color: Colors.white,
                    size: fontSize,
                  ),
                ),
              ),
            )),
      ],
    );
  }

  Widget cardListWidget(List<int> list, double fontSize) {
    return SafeArea(
      child: GestureDetector(
        onTap: () {
          setState(() {
            shownCardIndex = -1;
            ws!.sink.add('{"command": "show", "index": null}');
          });
        },
        child: Stack(
          children: [
            Padding(
              padding: EdgeInsets.all(fontSize),
              child: SafeArea(
                  child: GridView.count(
                crossAxisCount: 4,
                childAspectRatio: 2,
                mainAxisSpacing: 10,
                crossAxisSpacing: 10,
                children: List<Widget>.from(list.map((i) {
                  if (i >= submissions.length) return Container();
                  return GestureDetector(
                    onTap: () {
                      setState(() {
                        shownCardIndex = i;
                        ws!.sink.add('{"command": "show", "index": $i}');
                      });
                    },
                    child: Container(
                        decoration: BoxDecoration(
                          borderRadius:
                              BorderRadius.all(Radius.circular(fontSize * 0.5)),
                          border: shownCardIndex == i
                              ? Border.all(
                                  color: Colors.blue,
                                  strokeAlign: StrokeAlign.outside,
                                  width: 3)
                              : null,
                          image: const DecorationImage(
                            image: AssetImage("data/white-paper-texture.jpg"),
                            fit: BoxFit.cover,
                          ),
                          boxShadow: const [
                            BoxShadow(
                                color: Color.fromARGB(0x80, 0, 0, 0),
                                blurRadius: 5),
                          ],
                        ),
                        child: submissions[i]),
                  );
                })),
              )),
            ),
          ],
        ),
      ),
    );
  }

  Widget buildModeHost(BuildContext context, double fontSize) {
    return NotifyingPageView(
      notifier: _pageNotifier,
      controller: _pageController,
      physics: canSwipePage
          ? const ScrollPhysics()
          : const NeverScrollableScrollPhysics(),
      children: [
        cardListWidget(discussList, fontSize),
        SafeArea(
          child: Padding(
            padding: EdgeInsets.symmetric(vertical: fontSize * 0.5),
            child: Stack(
              children: [
                Stack(
                  children: [
                    Column(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Expanded(
                            child: Padding(
                              padding: EdgeInsets.symmetric(
                                  vertical: fontSize, horizontal: fontSize * 3),
                              child: GestureDetector(
                                onPanDown: (details) {
                                  setState(() {
                                    canSwipePage = false;
                                  });
                                },
                                onPanEnd: (details) {
                                  setState(() {
                                    canSwipePage = true;
                                  });
                                },
                                onPanCancel: () {
                                  setState(() {
                                    canSwipePage = true;
                                  });
                                },
                                child: SwipableStack(
                                  controller: _controller,
                                  stackClipBehaviour: Clip.none,
                                  onSwipeCompleted: (index, direction) {
                                    if (direction == SwipeDirection.right) {
                                      // accept answer
                                      ws!.sink.add(
                                          '{"command": "react", "reaction": "accept", "index": $index}');
                                      setState(() {
                                        acceptCount += 1;
                                        acceptList.add(index);
                                      });
                                    } else if (direction ==
                                        SwipeDirection.left) {
                                      // answer will be discussed
                                      ws!.sink.add(
                                          '{"command": "react", "reaction": "discuss", "index": $index}');
                                      setState(() {
                                        discussCount += 1;
                                        discussList.add(index);
                                      });
                                    } else if (direction == SwipeDirection.up) {
                                      // reject answer, try again
                                      ws!.sink.add(
                                          '{"command": "react", "reaction": "reject", "index": $index}');
                                    }
                                  },
                                  swipeAnchor: SwipeAnchor.top,
                                  onWillMoveNext: (index, direction) {
                                    final allowedActions = [
                                      SwipeDirection.right,
                                      SwipeDirection.left,
                                      SwipeDirection.up,
                                    ];
                                    return allowedActions.contains(direction);
                                  },
                                  horizontalSwipeThreshold: 0.8,
                                  verticalSwipeThreshold: 0.8,
                                  builder: (context, properties) {
                                    if (properties.index >=
                                        submissions.length) {
                                      return Container();
                                    }
                                    return Center(
                                      child: AspectRatio(
                                        aspectRatio: 2,
                                        child: GestureDetector(
                                          onDoubleTap: () {
                                            if (kDebugMode) {
                                              setState(() {
                                                showExampleImage = true;
                                              });
                                            }
                                          },
                                          child: Card(
                                            elevation: 10,
                                            child: Container(
                                              decoration: BoxDecoration(
                                                borderRadius:
                                                    BorderRadius.circular(
                                                        fontSize * 0.25),
                                                image: const DecorationImage(
                                                    image: AssetImage(
                                                        "data/white-paper-texture.jpg"),
                                                    filterQuality:
                                                        FilterQuality.high,
                                                    fit: BoxFit.cover),
                                              ),
                                              child: (kDebugMode &&
                                                      showExampleImage)
                                                  ? Image(
                                                      image: AssetImage(
                                                      'data/example.png',
                                                    ))
                                                  : Container(
                                                      width: double.infinity,
                                                      height: double.infinity,
                                                      child: submissions[
                                                          properties.index],
                                                    ),
                                            ),
                                          ),
                                        ),
                                      ),
                                    );
                                  },
                                ),
                              ),
                            ),
                          ),
                          Padding(
                            padding: EdgeInsets.all(fontSize * 0.5),
                            child: TweenAnimationBuilder<double>(
                              duration: const Duration(milliseconds: 250),
                              curve: Curves.easeInOut,
                              tween: Tween<double>(
                                begin: 0,
                                end: participantCount == 0
                                    ? 0
                                    : nonRejectedSubmissionCount /
                                        participantCount,
                              ),
                              builder: (context, value, _) =>
                                  LinearProgressIndicator(
                                value: value,
                                backgroundColor: Colors.white38,
                                color: Colors.white,
                              ),
                            ),
                          ),
                          Padding(
                            padding: EdgeInsets.symmetric(
                                horizontal: fontSize * 0.5),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Row(children: [
                                  Row(
                                      mainAxisSize: MainAxisSize.min,
                                      mainAxisAlignment:
                                          MainAxisAlignment.center,
                                      children: [
                                        if (!taskRunning)
                                          SlimButton(
                                            label:
                                                'Verbunden: $participantCount',
                                            fontSize: fontSize,
                                          ),
                                        if (taskRunning)
                                          SlimButton(
                                            label:
                                                'Antworten: $nonRejectedSubmissionCount von $participantCount',
                                            fontSize: fontSize,
                                          ),
                                      ]),
                                ]),
                                Row(children: [
                                  if (participantCount > 0)
                                    SlimButton(
                                      label: 'Neue Runde',
                                      fontSize: fontSize,
                                      onPressed: () {
                                        ws!.sink.add('{"command": "new_task"}');
                                        setState(() {
                                          rejectCount = 0;
                                          acceptCount = 0;
                                          discussCount = 0;
                                          shownCardIndex = -1;
                                          ws!.sink.add(
                                              '{"command": "show", "index": null}');

                                          acceptList.clear();
                                          discussList.clear();
                                          submissions.clear();
                                          _controller!.removeListener(
                                              _listenController);
                                          _controller!.dispose();
                                          _controller =
                                              SwipableStackController()
                                                ..addListener(
                                                    _listenController);
                                        });
                                      },
                                    ),
                                  SlimButton(
                                      label: 'Quiz beenden',
                                      fontSize: fontSize,
                                      onPressed: () {
                                        ws!.sink
                                            .add('{"command": "remove_game"}');
                                        SharedPreferences.getInstance()
                                            .then((prefs) {
                                          prefs.remove('sid');
                                        });
                                        disconnect();
                                      }),
                                ]),
                              ],
                            ),
                          ),
                        ]),
                    if (taskRunning)
                      Align(
                        alignment: Alignment.topCenter,
                        child:
                            Text('⛔', style: TextStyle(fontSize: fontSize * 2)),
                      ),
                  ],
                ),
                if (taskRunning)
                  pageSwapWidget(
                    fontSize: fontSize,
                    alignment: Alignment.centerLeft,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text('🤔', style: TextStyle(fontSize: fontSize * 2)),
                        CircleAvatar(
                          radius: fontSize,
                          backgroundColor:
                              const Color.fromARGB(192, 255, 255, 255),
                          foregroundColor: Colors.black,
                          child: AnimatedFlipCounter(
                            duration: const Duration(milliseconds: 200),
                            value: discussCount,
                            textStyle: TextStyle(fontSize: fontSize),
                          ),
                        ),
                      ],
                    ),
                  ),
                if (taskRunning)
                  pageSwapWidget(
                    fontSize: fontSize,
                    alignment: Alignment.centerRight,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text('😀', style: TextStyle(fontSize: fontSize * 2)),
                        CircleAvatar(
                          radius: fontSize,
                          backgroundColor:
                              const Color.fromARGB(192, 255, 255, 255),
                          foregroundColor: Colors.black,
                          child: AnimatedFlipCounter(
                            duration: const Duration(milliseconds: 200),
                            value: acceptCount,
                            textStyle: TextStyle(fontSize: fontSize),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
        cardListWidget(acceptList, fontSize),
      ],
    );
  }

  Widget pageSwapWidget({child, fontSize, alignment, onTap}) {
    return Align(
      alignment: alignment,
      child: SizedBox(
        width: fontSize * 4,
        child: Transform.scale(
          scaleX: alignment == Alignment.centerLeft ? -1 : 1,
          child: GestureDetector(
            onTap: onTap,
            child: Padding(
              padding: EdgeInsets.only(left: fontSize),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Transform.scale(
                    scaleX: alignment == Alignment.centerLeft ? -1 : 1,
                    child: child),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget buildModeDisplay(BuildContext context, double fontSize) {
    return Stack(children: [
      SizedBox(
        width: double.infinity,
        height: double.infinity,
        child: (showIndex != null)
            ? Padding(
                padding: EdgeInsets.all(fontSize * 0.5),
                child: Center(
                  child: AspectRatio(
                    aspectRatio: 2,
                    child: Container(
                      decoration: BoxDecoration(
                        image: const DecorationImage(
                          image: AssetImage("data/white-paper-texture.jpg"),
                          fit: BoxFit.cover,
                        ),
                        borderRadius: BorderRadius.circular(fontSize),
                        boxShadow: [
                          BoxShadow(
                              color: const Color(0x80000000),
                              blurRadius: fontSize),
                        ],
                      ),
                      child: Container(
                          width: double.infinity,
                          height: double.infinity,
                          child: Image.memory(
                            base64Decode(showPng!),
                            fit: BoxFit.cover,
                          )),
                    ),
                  ),
                ),
              )
            : Column(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                    Padding(
                      padding: EdgeInsets.only(top: fontSize),
                      child: Column(
                        children: [
                          Card(
                            elevation: 10,
                            child: Padding(
                              padding:
                                  EdgeInsets.fromLTRB(fontSize, 0, fontSize, 0),
                              child: Column(
                                children: [
                                  Padding(
                                    padding: EdgeInsets.all(fontSize),
                                    child: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Text(
                                          taskRunning
                                              ? 'PIN: $participantPin'
                                              : 'Bitte gib die folgende PIN ein:',
                                          style: TextStyle(
                                              fontSize: taskRunning
                                                  ? fontSize * 1.2
                                                  : fontSize * 1.4),
                                        ),
                                        if (!taskRunning)
                                          Text(
                                            '$participantPin',
                                            style: TextStyle(
                                                fontSize: fontSize * 2.4,
                                                fontWeight: FontWeight.bold),
                                          ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          if (!taskRunning)
                            Card(
                              elevation: 10,
                              child: Padding(
                                padding: EdgeInsets.fromLTRB(
                                    fontSize, 0, fontSize, fontSize),
                                child: Column(
                                  children: [
                                    Padding(
                                      padding: EdgeInsets.only(top: fontSize),
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Text(
                                            'Verbunden: ',
                                            style: TextStyle(
                                                fontSize: fontSize * 1.4),
                                          ),
                                          AnimatedFlipCounter(
                                            duration: const Duration(
                                                milliseconds: 500),
                                            value: participantCount,
                                            textStyle: TextStyle(
                                                fontSize: fontSize * 1.4),
                                          )
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          if (taskRunning)
                            Align(
                              alignment: Alignment.center,
                              child: Card(
                                elevation: 10,
                                child: Padding(
                                  padding: EdgeInsets.fromLTRB(
                                      fontSize, 0, fontSize, fontSize),
                                  child: Column(
                                    children: [
                                      Padding(
                                        padding: EdgeInsets.only(top: fontSize),
                                        child: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Text(
                                              'Antworten: ',
                                              style: TextStyle(
                                                  fontSize: fontSize * 1.4),
                                            ),
                                            AnimatedFlipCounter(
                                              duration: const Duration(
                                                  milliseconds: 500),
                                              value: nonRejectedSubmissionCount,
                                              textStyle: TextStyle(
                                                  fontSize: fontSize * 1.4),
                                            ),
                                            Text(
                                              ' von ',
                                              style: TextStyle(
                                                  fontSize: fontSize * 1.4),
                                            ),
                                            AnimatedFlipCounter(
                                              duration: const Duration(
                                                  milliseconds: 500),
                                              value: participantCount,
                                              textStyle: TextStyle(
                                                  fontSize: fontSize * 1.4),
                                            ),
                                          ],
                                        ),
                                      ),
                                      Padding(
                                        padding: EdgeInsets.all(fontSize),
                                        child: SizedBox(
                                            width: fontSize * 6,
                                            height: fontSize * 6,
                                            child:
                                                TweenAnimationBuilder<double>(
                                              duration: const Duration(
                                                  milliseconds: 250),
                                              curve: Curves.easeInOut,
                                              tween: Tween<double>(
                                                begin: 0,
                                                end: participantCount == 0
                                                    ? 0
                                                    : nonRejectedSubmissionCount /
                                                        participantCount,
                                              ),
                                              builder: (context, value, _) =>
                                                  CircularProgressIndicator(
                                                backgroundColor:
                                                    Colors.blue[100],
                                                color: Colors.blue[600],
                                                value: value,
                                                strokeWidth: 8,
                                              ),
                                            )),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ]),
      ),
      Align(
          alignment: Alignment.bottomRight,
          child: InkWell(
            onTap: () {
              disconnect();
            },
            child: Container(
              decoration: BoxDecoration(
                color: const Color(0x40000000),
                borderRadius: BorderRadius.circular(fontSize),
              ),
              child: Padding(
                padding: EdgeInsets.all(fontSize * 0.3),
                child: Icon(
                  Icons.logout,
                  color: Colors.white,
                  size: fontSize,
                ),
              ),
            ),
          )),
    ]);
  }

  Widget buildModeParticipant(BuildContext context, double fontSize) {
    if (!taskRunning) {
      return Stack(
        children: [
          Center(
            child: Card(
              child: Padding(
                padding: EdgeInsets.all(fontSize),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (sentCardReaction == null)
                      Text(
                        sentCard
                            ? 'Deine Karte wurde gesendet.'
                            : 'Du bist verbunden!',
                        style: TextStyle(fontSize: fontSize),
                      ),
                    if (sentCardReaction == 'accept')
                      Text(
                        'Deine Antwort ist richtig!',
                        style: TextStyle(fontSize: fontSize),
                      ),
                    if (sentCardReaction == 'accept')
                      Padding(
                        padding: EdgeInsets.all(fontSize / 2),
                        child: Text(
                          '😀',
                          style: TextStyle(fontSize: fontSize * 2.5),
                        ),
                      ),
                    if (sentCardReaction == 'discuss')
                      Text(
                        'Deine Antwort wird gleich besprochen.',
                        style: TextStyle(fontSize: fontSize),
                      ),
                    if (sentCardReaction == 'discuss')
                      Padding(
                        padding: const EdgeInsets.all(8.0),
                        child: Text(
                          '🤔',
                          style: TextStyle(fontSize: fontSize * 2.5),
                        ),
                      ),
                    if (!sentCard)
                      Padding(
                        padding: EdgeInsets.only(top: fontSize * 0.5),
                        child: Text(
                          'Bitte warte kurz auf die nächste Aufgabe.',
                          style: TextStyle(fontSize: fontSize),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
          Align(
              alignment: Alignment.bottomRight,
              child: InkWell(
                onTap: () {
                  disconnect();
                },
                child: Container(
                  decoration: BoxDecoration(
                    color: const Color(0x40000000),
                    borderRadius: BorderRadius.circular(fontSize),
                  ),
                  child: Padding(
                    padding: EdgeInsets.all(fontSize * 0.3),
                    child: Icon(
                      Icons.logout,
                      color: Colors.white,
                      size: fontSize,
                    ),
                  ),
                ),
              )),
        ],
      );
    }
    return LayoutBuilder(builder: (context, constraints) {
      double maxWidth = constraints.maxWidth;
      // double maxHeight = constraints.maxHeight;
      double sideWidth = fontSize * 5;
      maxWidth -= sideWidth;
      double height = maxWidth / 2;
      return Padding(
        padding: EdgeInsets.all(fontSize * 0.5),
        child: Stack(
          children: [
            Padding(
              padding: EdgeInsets.fromLTRB(0, 0, sideWidth, 0),
              child: Center(
                child: AnimatedBuilder(
                  animation: participantCardAnimationController,
                  builder: (context, widget) {
                    return Transform.translate(
                      offset: Offset(
                          participantCardAnimationController.value *
                              maxWidth *
                              1.5,
                          0),
                      child: AspectRatio(
                        aspectRatio: 2,
                        child: Container(
                          decoration: BoxDecoration(
                            borderRadius:
                                BorderRadius.all(Radius.circular(fontSize)),
                            color: Colors.white,
                            image: const DecorationImage(
                              image: AssetImage("data/white-paper-texture.jpg"),
                              fit: BoxFit.cover,
                            ),
                            boxShadow: [
                              BoxShadow(
                                  color: const Color(0x80000000),
                                  blurRadius: fontSize),
                            ],
                          ),
                          child: GestureDetector(
                            onPanDown: (DragDownDetails details) {
                              setState(() {
                                drawing.lines.add(Line(
                                    color: Colors.black,
                                    lineWidth: 1.5,
                                    clearMode: clearMode));
                                drawing.lines.last.points
                                    .add(details.localPosition / cardScale);
                              });
                            },
                            onPanUpdate: (DragUpdateDetails details) {
                              setState(() {
                                drawing.lines.last.points
                                    .add(details.localPosition / cardScale);
                              });
                            },
                            onPanEnd: (DragEndDetails details) {
                              updateImage();
                            },
                            child: RepaintBoundary(
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(fontSize),
                                child: Stack(
                                  children: [
                                    GestureDetector(
                                      onDoubleTap: () {
                                        if (kDebugMode) {
                                          setState(() {
                                            showExampleImage = true;
                                          });
                                        }
                                      },
                                      child: CustomPaint(
                                        painter: ArgosPainter(drawing: drawing),
                                        child: (image != null)
                                            ? RawImage(
                                                width: double.infinity,
                                                height: double.infinity,
                                                image: image,
                                                fit: BoxFit.cover,
                                              )
                                            : null,
                                      ),
                                    ),
                                    if (showExampleImage)
                                      const Expanded(
                                        child: Image(
                                            fit: BoxFit.cover,
                                            width: double.infinity,
                                            height: double.infinity,
                                            image:
                                                AssetImage("data/example.png")),
                                      ),
                                    if (sentCardReaction == 'reject')
                                      Padding(
                                        padding: EdgeInsets.all(fontSize * 0.0),
                                        child: Align(
                                          alignment: Alignment.bottomCenter,
                                          child: Container(
                                            decoration: const BoxDecoration(
                                              color: Color(0xc0ffffff),
                                            ),
                                            child: Padding(
                                              padding: EdgeInsets.symmetric(
                                                  vertical: fontSize * 0.5,
                                                  horizontal: fontSize),
                                              child: Text(
                                                  "Deine Antwort wurde abgelehnt. Bitte versuche es noch einmal.",
                                                  style: TextStyle(
                                                      fontSize: maxWidth / 40)),
                                            ),
                                          ),
                                        ),
                                      )
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: SizedBox(
                height: height,
                width: sideWidth,
                child: Padding(
                  padding: EdgeInsets.symmetric(vertical: fontSize * 0.5),
                  child: AnimatedBuilder(
                    animation: participantCardAnimationController,
                    builder: (context, widget) {
                      return Column(
                          crossAxisAlignment: CrossAxisAlignment.center,
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          mainAxisSize: MainAxisSize.max,
                          children: [
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.center,
                              mainAxisAlignment: MainAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Transform.translate(
                                  offset: Offset(
                                      participantCardAnimationController.value *
                                          sideWidth,
                                      0),
                                  child: Padding(
                                    padding: EdgeInsets.all(fontSize * 0.25),
                                    child: RawMaterialButton(
                                      onPressed: !clearMode
                                          ? null
                                          : () => setState(() {
                                                clearMode = false;
                                              }),
                                      elevation: 2.0,
                                      fillColor: clearMode
                                          ? Colors.grey[400]
                                          : Colors.blue,
                                      padding: EdgeInsets.all(fontSize * 0.8),
                                      shape: const CircleBorder(),
                                      child: Icon(Icons.brush,
                                          size: fontSize * 1.2,
                                          color: Colors.white),
                                    ),
                                  ),
                                ),
                                Transform.translate(
                                  offset: Offset(
                                      participantCardAnimationController.value *
                                          sideWidth,
                                      0),
                                  child: Padding(
                                    padding: EdgeInsets.all(fontSize * 0.25),
                                    child: RawMaterialButton(
                                      onPressed: clearMode
                                          ? null
                                          : () => setState(() {
                                                clearMode = true;
                                              }),
                                      elevation: 2.0,
                                      fillColor: !clearMode
                                          ? Colors.grey[400]
                                          : Colors.blue,
                                      padding: EdgeInsets.all(fontSize * 0.8),
                                      shape: const CircleBorder(),
                                      child: Icon(CommunityMaterialIcons.eraser,
                                          size: fontSize * 1.2,
                                          color: Colors.white),
                                    ),
                                  ),
                                ),
                                Transform.translate(
                                  offset: Offset(
                                      participantCardAnimationController.value *
                                          sideWidth,
                                      0),
                                  child: Padding(
                                    padding: EdgeInsets.all(fontSize * 0.25),
                                    child: RawMaterialButton(
                                      onPressed: () => clearImage(),
                                      elevation: 2.0,
                                      fillColor: Colors.red[400],
                                      padding: EdgeInsets.all(fontSize * 0.8),
                                      shape: const CircleBorder(),
                                      child: Icon(
                                          CommunityMaterialIcons.trash_can,
                                          size: fontSize * 1.2,
                                          color: Colors.white),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.center,
                              mainAxisAlignment: MainAxisAlignment.end,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Transform.translate(
                                  offset: Offset(
                                      participantCardAnimationController.value *
                                          sideWidth,
                                      0),
                                  child: Padding(
                                    padding: EdgeInsets.all(fontSize * 0.25),
                                    child: RawMaterialButton(
                                      onPressed: (image == null)
                                          ? null
                                          : () {
                                              setState(() {
                                                sentCardReaction = null;
                                                sendImage();
                                                participantCardAnimationController
                                                    .animateTo(1.0,
                                                        curve: Curves.easeIn)
                                                    .then((x) {
                                                  setState(() {
                                                    taskRunning = false;
                                                  });
                                                });
                                              });
                                            },
                                      elevation: 2.0,
                                      fillColor: Colors.green[400],
                                      padding: EdgeInsets.all(fontSize * 0.8),
                                      shape: const CircleBorder(),
                                      child: Icon(Icons.send,
                                          size: fontSize * 1.2,
                                          color: Colors.white),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ]);
                    },
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    });
  }
}
