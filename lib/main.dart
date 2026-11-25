import 'dart:convert';
import 'dart:io';

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

// ---------- Diseño de los botones (medidas de referencia 1600x720, como Kirin) ----------

class Spec {
  final double x, y, r;
  const Spec(this.x, this.y, this.r);
}

const Map<String, Spec> kDefaults = {
  'dpad': Spec(248, 554, 114),
  'a': Spec(1238, 552, 78),
  'b': Spec(1408, 595, 66),
  'l': Spec(1108, 616, 42),
  'r': Spec(1428, 467, 32),
  'start': Spec(1238, 405, 32),
  'select': Spec(1333, 405, 32),
  'ff': Spec(1462, 314, 32),
};

const Map<String, String> kNames = {
  'dpad': 'Cruceta',
  'a': 'A',
  'b': 'B',
  'l': 'L',
  'r': 'R',
  'start': 'Start',
  'select': 'Select',
  'ff': 'Avance rápido',
};

const Map<String, String> kLabels = {
  'a': 'A',
  'b': 'B',
  'l': 'L',
  'r': 'R',
  'start': 'Start',
  'select': 'Select',
  'ff': '▶▶',
};

const List<String> kStepNames = ['SM', 'MD', 'LG', 'XL', 'XXL'];
const List<double> kStepMul = [0.75, 1.0, 1.25, 1.5, 1.8];
const List<String> kRound = ['a', 'b', 'l', 'r', 'start', 'select'];

const Color kAccent = Color(0xFFB0214F);
const Color kFfBlue = Color(0xFF4C8DFF);

File? _settingsFile() {
  try {
    final dir = Directory('${Directory.systemTemp.parent.path}/files');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return File('${dir.path}/egba_settings.json');
  } catch (_) {
    return null;
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
  bool editing = false;
  String? selected;
  double scale = 1.0;
  double opacity = 1.0;
  bool vibrate = true;
  final Map<String, Offset> pos = {
    for (final e in kDefaults.entries) e.key: Offset(e.value.x, e.value.y)
  };
  final Map<String, int> step = {for (final k in kDefaults.keys) k: 1};

  @override
  void initState() {
    super.initState();
    _load();
    WidgetsBinding.instance.addPostFrameCallback((_) => _checkCrash());
  }

  // ---------- Guardado ----------

  Future<void> _load() async {
    try {
      final f = _settingsFile();
      if (f == null || !await f.exists()) return;
      final m = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      setState(() {
        scale = ((m['scale'] ?? 1.0) as num).toDouble().clamp(0.4, 1.4).toDouble();
        opacity = ((m['opacity'] ?? 1.0) as num).toDouble().clamp(0.0, 1.0).toDouble();
        vibrate = (m['vibrate'] ?? true) as bool;
        final items = (m['items'] ?? {}) as Map<String, dynamic>;
        items.forEach((k, v) {
          if (!kDefaults.containsKey(k)) return;
          final it = v as Map<String, dynamic>;
          pos[k] = Offset((it['x'] as num).toDouble(), (it['y'] as num).toDouble());
          step[k] = ((it['s'] ?? 1) as num).toInt().clamp(0, kStepMul.length - 1).toInt();
        });
      });
    } catch (_) {}
  }

  Future<void> _save() async {
    try {
      final f = _settingsFile();
      if (f == null) return;
      final data = {
        'scale': scale,
        'opacity': opacity,
        'vibrate': vibrate,
        'items': {
          for (final k in kDefaults.keys)
            k: {'x': pos[k]!.dx, 'y': pos[k]!.dy, 's': step[k]}
        },
      };
      await f.writeAsString(jsonEncode(data));
    } catch (_) {}
  }

  // ---------- Acciones ----------

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

  void _buzz() {
    if (vibrate) HapticFeedback.selectionClick();
  }

  void _resetLayout() {
    setState(() {
      for (final e in kDefaults.entries) {
        pos[e.key] = Offset(e.value.x, e.value.y);
        step[e.key] = 1;
      }
    });
    _save();
  }

  Future<void> _openSettings() async {
    setState(() => menuOpen = false);
    const label = TextStyle(color: Colors.white70, fontSize: 13);
    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setD) {
        void both(VoidCallback f) {
          setState(f);
          setD(() {});
        }

        return AlertDialog(
          backgroundColor: const Color(0xFF16181D),
          title: const Text('Configuración', style: TextStyle(color: Colors.white)),
          content: SizedBox(
            width: 380,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Escala del gamepad   ${(scale * 100).round()}%', style: label),
                  Slider(
                    value: scale,
                    min: 0.4,
                    max: 1.4,
                    activeColor: kAccent,
                    onChanged: (v) => both(() => scale = v),
                  ),
                  Text('Opacidad del gamepad   ${(opacity * 100).round()}%', style: label),
                  Slider(
                    value: opacity,
                    min: 0.0,
                    max: 1.0,
                    activeColor: kAccent,
                    onChanged: (v) => both(() => opacity = v),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Vibración de botones', style: label),
                    value: vibrate,
                    activeColor: kAccent,
                    onChanged: (v) => both(() => vibrate = v),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cerrar', style: TextStyle(color: kAccent)),
            ),
          ],
        );
      }),
    );
    _save();
  }

  // ---------- Pantalla de juego ----------

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

        double rpx(String id) => kDefaults[id]!.r * kStepMul[step[id]!] * scale / 720 * h;
        Offset center(String id) => Offset(pos[id]!.dx / 1600 * w, pos[id]!.dy / 720 * h);

        // Coloca un botón; en modo edición se puede tocar para elegir y arrastrar para mover.
        Widget placed(String id, Widget Function(double size) build) {
          final r = rpx(id);
          final ctr = center(id);
          Widget inner = build(r * 2);
          if (editing) {
            inner = GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => setState(() => selected = id),
              onPanStart: (_) => setState(() => selected = id),
              onPanUpdate: (d) => setState(() {
                final p = pos[id]!;
                pos[id] = Offset(
                  (p.dx + d.delta.dx * 1600 / w).clamp(0.0, 1600.0).toDouble(),
                  (p.dy + d.delta.dy * 720 / h).clamp(0.0, 720.0).toDouble(),
                );
              }),
              onPanEnd: (_) => _save(),
              child: inner,
            );
          }
          return Positioned(
            left: ctr.dx - r,
            top: ctr.dy - r,
            width: r * 2,
            height: r * 2,
            child: inner,
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

          if (controlsVisible || editing) ...[
            placed(
              'dpad',
              (size) => editing
                  ? DPadFace(size: size, opacity: opacity, selected: selected == 'dpad')
                  : DPad(size: size, opacity: opacity, onDown: _buzz),
            ),
            for (final id in kRound)
              placed(
                id,
                (size) => editing
                    ? ButtonFace(
                        label: kLabels[id]!,
                        size: size,
                        opacity: opacity,
                        selected: selected == id,
                      )
                    : PadButton(
                        label: kLabels[id]!,
