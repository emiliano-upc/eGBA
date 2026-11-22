import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  runApp(const MaterialApp(
    debugShowCheckedModeBanner: false,
    home: GbaPage(),
  ));
}

/// Puente con el lado nativo (LibretroDroid + mGBA).
class EmulatorBridge {
  static const _ch = MethodChannel('gba/emulator');

  static Future<String?> pickRom() => _call<String>('pickRom');
  static Future<String?> getLastCrash() => _call<String>('getLastCrash');
  static Future<void> setKey(String key, bool pressed) =>
      _call('setKey', {'key': key, 'pressed': pressed});
  static Future<void> reset() => _call('reset');
  static Future<void> saveState() => _call('saveState');
  static Future<void> loadState() => _call('loadState');
  static Future<void> setFastForward(bool on) =>
      _call('setFastForward', {'on': on});

  static Future<T?> _call<T>(String m, [Object? args]) async {
    try {
      return await _ch.invokeMethod<T>(m, args);
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }
}

class GbaPage extends StatefulWidget {
  const GbaPage({super.key});
  @override
  State<GbaPage> createState() => _GbaPageState();
}

class _GbaPageState extends State<GbaPage> {
  String? romPath;
  bool menuOpen = false;
  bool controlsVisible = true;
  bool fastForward = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _checkCrash());
  }

  Future<void> _checkCrash() async {
    final report = await EmulatorBridge.getLastCrash();
    if (report == null || !mounted) return;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('La app se cerró la última vez'),
        content: SingleChildScrollView(
          child: SelectableText(report, style: const TextStyle(fontSize: 11)),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cerrar')),
        ],
      ),
    );
  }

  Future<void> _openRom() async {
    final path = await EmulatorBridge.pickRom();
    if (path == null) return;
    setState(() => romPath = path);
  }

  void _toggleFF() {
    setState(() => fastForward = !fastForward);
    EmulatorBridge.setFastForward(fastForward);
  }

  Widget _gameView(String rom) {
    const viewType = 'egba/retro_view';
    return PlatformViewLink(
      key: ValueKey(rom),
      viewType: viewType,
      surfaceFactory: (context, controller) {
        return AndroidViewSurface(
          controller: controller as AndroidViewController,
          gestureRecognizers: const <Factory<OneSequenceGestureRecognizer>>{},
          hitTestBehavior: PlatformViewHitTestBehavior.transparent,
        );
      },
      onCreatePlatformView: (params) {
        return PlatformViewsService.initExpensiveAndroidView(
          id: params.id,
          viewType: viewType,
          layoutDirection: TextDirection.ltr,
          creationParams: {'rom': rom},
          creationParamsCodec: const StandardMessageCodec(),
          onFocus: () => params.onFocusChanged(true),
        )
          ..addOnPlatformViewCreatedListener(params.onPlatformViewCreated)
          ..create();
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: LayoutBuilder(builder: (context, c) {
        final w = c.maxWidth, h = c.maxHeight;

        // Posiciona un círculo usando las proporciones de la pantalla de Kirin (1600x720).
        Widget key(String label, String id, double x, double y, double r) {
          final rr = r / 720 * h;
          return Positioned(
            left: x / 1600 * w - rr,
            top: y / 720 * h - rr,
            child: PadButton(label: label, size: rr * 2, onChange: (p) => EmulatorBridge.setKey(id, p)),
          );
        }

        return Stack(children: [
          // Pantalla del juego: toda la altura, centrada, relación 3:2.
          Center(
            child: AspectRatio(
              aspectRatio: 3 / 2,
              child: romPath != null
                  ? _gameView(romPath!)
                  : Center(
                      child: OutlinedButton(
                        onPressed: _openRom,
                        child: const Text('Abrir ROM (.gba)'),
                      ),
                    ),
            ),
          ),

          if (controlsVisible) ...[
            Positioned(
              left: 134 / 1600 * w,
              top: 440 / 720 * h,
              child: DPad(size: 228 / 720 * h),
            ),
            key('A', 'a', 1238, 552, 78),
            key('B', 'b', 1408, 595, 66),
            key('L', 'l', 1108, 616, 42),
            key('R', 'r', 1428, 467, 32),
            key('Start', 'start', 1238, 405, 32),
            key('Select', 'select', 1333, 405, 32),
          ],

          // Avance rápido (mantener apretado).
          Positioned(
            left: 1462 / 1600 * w - 32 / 720 * h,
            top: 314 / 720 * h - 32 / 720 * h,
            child: PadButton(
              label: '▶▶',
              size: 64 / 720 * h,
              onChange: EmulatorBridge.setFastForward,
            ),
          ),

          // Menú arriba a la derecha.
          Positioned(
            top: 12,
            right: 12,
            child: menuOpen ? _expandedMenu() : _menuButton(Icons.apps, () => setState(() => menuOpen = true)),
          ),
        ]);
      }),
    );
  }

  Widget _menuButton(IconData icon, VoidCallback onTap, {Color? color}) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 54,
        height: 54,
        margin: const EdgeInsets.all(4),
        decoration: const BoxDecoration(color: Color(0xCC2A2D33), shape: BoxShape.circle),
        child: Icon(icon, color: color ?? Colors.white70, size: 26),
      ),
    );
  }

  Widget _expandedMenu() {
    final items = <(IconData, VoidCallback)>[
      (Icons.restart_alt, EmulatorBridge.reset),
      (Icons.save_alt, EmulatorBridge.saveState),
      (Icons.upload_file, EmulatorBridge.loadState),
      (Icons.edit, () {}), // editar posición/tamaño de botones (pendiente)
      (Icons.settings, () {}), // ajustes (pendiente)
      (Icons.folder_open, _openRom),
      (Icons.gamepad, () => setState(() => controlsVisible = !controlsVisible)),
      (Icons.fast_forward, _toggleFF),
    ];
    Widget row(int from) => Row(
          children: [for (var i = from; i < from + 4; i++) _menuButton(items[i].$1, items[i].$2)],
        );
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Column(children: [row(0), row(4)]),
        IconButton(
          icon: const Icon(Icons.chevron_right, color: Colors.white, size: 32),
          onPressed: () => setState(() => menuOpen = false),
        ),
      ],
    );
  }
}

/// Botón circular con contorno fino y sin relleno. Soporta multitoque.
class PadButton extends StatefulWidget {
  final String label;
  final double size;
  final ValueChanged<bool> onChange;
  const PadButton({super.key, required this.label, required this.size, required this.onChange});
  @override
  State<PadButton> createState() => _PadButtonState();
}

class _PadButtonState extends State<PadButton> {
  bool down = false;
  void _set(bool v) {
    if (down == v) return;
    setState(() => down = v);
    widget.onChange(v);
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: (_) => _set(true),
      onPointerUp: (_) => _set(false),
      onPointerCancel: (_) => _set(false),
      child: Container(
        width: widget.size,
        height: widget.size,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: down ? Colors.white.withOpacity(0.15) : Colors.transparent,
          border: Border.all(color: Colors.white.withOpacity(0.35), width: 1),
        ),
        child: Text(widget.label,
            style: TextStyle(color: Colors.white.withOpacity(0.5), fontSize: widget.size * 0.28)),
      ),
    );
  }
}

/// Cruceta en forma de cruz. Deslizar el dedo cambia la dirección; admite diagonales.
class DPad extends StatefulWidget {
  final double size;
  const DPad({super.key, required this.size});
  @override
  State<DPad> createState() => _DPadState();
}

class _DPadState extends State<DPad> {
  final Set<String> _down = {};

  void _update(Offset p) {
    final c = widget.size / 2;
    final dx = p.dx - c, dy = p.dy - c;
    final dead = widget.size * 0.12;
    final now = <String>{
      if (dx < -dead) 'left',
      if (dx > dead) 'right',
      if (dy < -dead) 'up',
      if (dy > dead) 'down',
    };
    for (final k in _down.difference(now)) {
      EmulatorBridge.setKey(k, false);
    }
    for (final k in now.difference(_down)) {
      EmulatorBridge.setKey(k, true);
    }
    setState(() {
      _down
        ..clear()
        ..addAll(now);
    });
  }

  void _release() => _update(Offset(widget.size / 2, widget.size / 2));

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: (e) => _update(e.localPosition),
      onPointerMove: (e) => _update(e.localPosition),
      onPointerUp: (_) => _release(),
      onPointerCancel: (_) => _release(),
      child: SizedBox(
        width: widget.size,
        height: widget.size,
        child: CustomPaint(painter: _DPadPainter(_down)),
      ),
    );
  }
}

class _DPadPainter extends CustomPainter {
  final Set<String> pressed;
  _DPadPainter(this.pressed);

  @override
  void paint(Canvas canvas, Size s) {
    final a = s.width / 3; // ancho de cada brazo
    final r = Radius.circular(a * 0.12);
    final path = Path()
      ..addRRect(RRect.fromRectAndRadius(Rect.fromLTWH(a, 0, a, s.height), r))
      ..addRRect(RRect.fromRectAndRadius(Rect.fromLTWH(0, a, s.width, a), r));
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = Colors.white.withOpacity(0.35);
    canvas.drawPath(path, stroke);

    final fill = Paint()..color = Colors.white.withOpacity(0.15);
    if (pressed.contains('up')) canvas.drawRect(Rect.fromLTWH(a, 0, a, a), fill);
    if (pressed.contains('down')) canvas.drawRect(Rect.fromLTWH(a, 2 * a, a, a), fill);
    if (pressed.contains('left')) canvas.drawRect(Rect.fromLTWH(0, a, a, a), fill);
    if (pressed.contains('right')) canvas.drawRect(Rect.fromLTWH(2 * a, a, a, a), fill);

    final arrow = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round
      ..color = Colors.white.withOpacity(0.5);
    final m = a * 0.18;
    void chevron(Offset c, double dx, double dy) {
      canvas.drawLine(c + Offset(-dy * m - dx * m, dx * m - dy * m), c, arrow);
      canvas.drawLine(c + Offset(dy * m - dx * m, -dx * m - dy * m), c, arrow);
    }

    chevron(Offset(1.5 * a, 0.5 * a), 0, -1);
    chevron(Offset(1.5 * a, 2.5 * a), 0, 1);
    chevron(Offset(0.5 * a, 1.5 * a), -1, 0);
    chevron(Offset(2.5 * a, 1.5 * a), 1, 0);
  }

  @override
  bool shouldRepaint(_DPadPainter old) => old.pressed.length != pressed.length || !old.pressed.containsAll(pressed);
}
