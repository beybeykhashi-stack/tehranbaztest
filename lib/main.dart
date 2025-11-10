import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:system_tray/system_tray.dart';
import 'package:window_manager/window_manager.dart';

import 'clock.dart';
import 'player_controller.dart';
import 'schedule.dart';

const _kAppTitle = 'ChronoPlayer';
const _keepPlayingOnClose = true;
const _kTrayIconPngBase64 =
    'iVBORw0KGgoAAAANSUhEUgAAAAoAAAAKCAQAAACENnwnAAAAG0lEQVR42mP8//8/AzGAiYGIgQGB4T8QAJrHBB//uKxsAAAAAElFTkSuQmCC';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await MediaKit.ensureInitialized();
  DaySchedule schedule;
  try {
    schedule = await loadScheduleFromAssets('assets/schedule.json');
  } catch (error, stack) {
    runApp(_ErrorApp(message: 'Failed to load schedule: $error'));
    debugPrint('Schedule error: $error\n$stack');
    return;
  }
  await windowManager.ensureInitialized();
  const windowOptions = WindowOptions(
    size: Size(980, 620),
    center: true,
    backgroundColor: Colors.transparent,
    title: _kAppTitle,
  );
  windowManager.waitUntilReadyToShow(windowOptions, () async {
    await windowManager.show();
    await windowManager.focus();
    if (_keepPlayingOnClose) {
      await windowManager.setPreventClose(true);
    }
  });

  runApp(ChronoApp(schedule: schedule));
}

class ChronoApp extends StatelessWidget {
  const ChronoApp({super.key, required this.schedule});

  final DaySchedule schedule;

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) => PlayerController(schedule),
      child: MaterialApp(
        title: _kAppTitle,
        themeMode: ThemeMode.dark,
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: Colors.blueGrey, brightness: Brightness.dark),
          useMaterial3: true,
        ),
        debugShowCheckedModeBanner: false,
        home: const HomePage(),
      ),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WindowListener {
  StreamSubscription<DateTime>? _tickSubscription;
  late final DateFormat _timeFormat;
  SharedPreferences? _prefs;

  final SystemTray _systemTray = SystemTray();
  final Menu _trayMenu = Menu();
  String? _trayIconPath;

  @override
  void initState() {
    super.initState();
    _timeFormat = DateFormat('HH:mm:ss');
    windowManager.addListener(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _initialize());
  }

  Future<void> _initialize() async {
    final controller = context.read<PlayerController>();
    _prefs = await SharedPreferences.getInstance();
    final storedVolume = _prefs?.getDouble('volume');
    if (storedVolume != null) {
      await controller.setVolume(storedVolume);
    }
    await controller.playForNow(DateTime.now());
    _tickSubscription = alignedSecondTicks().listen((now) {
      controller.resyncIfDrifted(now);
      if (mounted) {
        setState(() {});
      }
    });
    await _setupTray();
  }

  Future<void> _setupTray() async {
    final iconPath = await _ensureTrayIcon();
    await _systemTray.initSystemTray(
      title: _kAppTitle,
      toolTip: _kAppTitle,
      iconPath: iconPath,
    );
    await _trayMenu.buildFrom([
      MenuItemLabel(label: 'Play/Pause', onClicked: (_) async => await _trayToggle()),
      MenuItemLabel(label: 'Next Track', onClicked: (_) async => await _trayNext()),
      MenuItemLabel(label: 'Show/Hide', onClicked: (_) async => await _trayToggleWindow()),
      const MenuSeparator(),
      MenuItemLabel(label: 'Quit', onClicked: (_) async => await _trayQuit()),
    ]);
    await _systemTray.setContextMenu(_trayMenu);
    _systemTray.registerSystemTrayEventHandler((eventName) async {
      if (eventName == kSystemTrayEventClick) {
        await _trayToggleWindow();
      }
    });
  }

  Future<String> _ensureTrayIcon() async {
    if (_trayIconPath != null) {
      return _trayIconPath!;
    }
    final bytes = base64Decode(_kTrayIconPngBase64);
    final iconFile = File(p.join(Directory.systemTemp.path, 'chronoplayer_tray.png'));
    await iconFile.writeAsBytes(bytes, flush: true);
    _trayIconPath = iconFile.path;
    return _trayIconPath!;
  }

  Future<void> _trayToggle() async {
    await context.read<PlayerController>().toggle();
  }

  Future<void> _trayNext() async {
    await context.read<PlayerController>().next();
  }

  Future<void> _trayToggleWindow() async {
    final isVisible = await windowManager.isVisible();
    if (isVisible) {
      await windowManager.hide();
    } else {
      await windowManager.show();
      await windowManager.focus();
    }
  }

  Future<void> _trayQuit() async {
    await _systemTray.destroy();
    await context.read<PlayerController>().disposeAsync();
    await windowManager.destroy();
    if (Platform.isLinux) {
      exit(0);
    }
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    _tickSubscription?.cancel();
    unawaited(_systemTray.destroy());
    super.dispose();
  }

  @override
  Future<void> onWindowClose() async {
    if (_keepPlayingOnClose) {
      await windowManager.hide();
    } else {
      await windowManager.destroy();
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<PlayerController>();
    final schedule = controller.schedule;
    final now = DateTime.now();
    final nowSec = nowSecondsOfDay(now);
    final currentIndex = schedule.indexForSecond(nowSec);
    final current = schedule[currentIndex];
    final next = schedule[schedule.nextIndex(currentIndex)];
    final secsIntoSlot = schedule.offsetSinceStart(nowSec);
    final secondsUntilNext = schedule.secondsUntilNextBoundary(nowSec);
    final slotLength = secsIntoSlot + secondsUntilNext;
    final slotProgress = slotLength > 0 ? secsIntoSlot / slotLength : 0.0;
    final nextLabel = next.startSec > current.startSec ? _formatTime(next.startSec) : '24:00:00';

    return Scaffold(
      backgroundColor: const Color(0xFF101218),
      body: SafeArea(
        child: Column(
          children: [
            if (controller.hasError)
              MaterialBanner(
                backgroundColor: Colors.red.shade900,
                content: Text(controller.errorMessage ?? 'Unknown playback error'),
                actions: [
                  TextButton(
                    onPressed: () => controller.clearError(),
                    child: const Text('Dismiss'),
                  ),
                ],
              ),
            Expanded(
              child: Row(
                children: [
                  _buildScheduleList(schedule, currentIndex),
                  const VerticalDivider(width: 1),
                  Expanded(child: _buildMainPane(controller, now, current, nextLabel, secsIntoSlot, slotLength, slotProgress)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildScheduleList(DaySchedule schedule, int currentIndex) {
    return SizedBox(
      width: 320,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.all(16.0),
            child: Text(
              'Schedule',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
          ),
          Expanded(
            child: ListView.builder(
              itemCount: schedule.entries.length,
              itemBuilder: (context, index) {
                final entry = schedule.entries[index];
                final isCurrent = index == currentIndex;
                return Container(
                  color: isCurrent ? Colors.white10 : Colors.transparent,
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  child: Row(
                    children: [
                      Text(
                        _formatTime(entry.startSec),
                        style: const TextStyle(fontFeatures: [FontFeature.tabularFigures()]),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          entry.file,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMainPane(
    PlayerController controller,
    DateTime now,
    ScheduleEntry current,
    String nextLabel,
    int secsIntoSlot,
    int slotLength,
    double slotProgress,
  ) {
    final actualPosition = controller.audioPosition;
    return Padding(
      padding: const EdgeInsets.all(24.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                _kAppTitle,
                style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
              ),
              Text(
                _timeFormat.format(now),
                style: const TextStyle(fontSize: 18, fontFeatures: [FontFeature.tabularFigures()]),
              ),
            ],
          ),
          const SizedBox(height: 20),
          Text(
            'Now playing',
            style: TextStyle(color: Colors.white.withOpacity(0.7)),
          ),
          const SizedBox(height: 8),
          Text(
            current.file,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 8),
          Text(
            'Slot: ${current.startLabel} → $nextLabel',
            style: TextStyle(color: Colors.white.withOpacity(0.6)),
          ),
          const SizedBox(height: 18),
          LinearProgressIndicator(value: slotProgress.clamp(0.0, 1.0)),
          const SizedBox(height: 8),
          Text(
            'In slot: ${_formatDuration(secsIntoSlot)} / ${_formatDuration(slotLength)}',
            style: TextStyle(color: Colors.white.withOpacity(0.7)),
          ),
          const SizedBox(height: 12),
          Text(
            'Audio position: ${_formatDuration(actualPosition.inSeconds)}',
            style: TextStyle(color: Colors.white.withOpacity(0.7)),
          ),
          const SizedBox(height: 24),
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 12,
            runSpacing: 12,
            children: [
              ElevatedButton(
                onPressed: () => controller.toggle(),
                child: Text(controller.playing ? 'Pause' : 'Play'),
              ),
              ElevatedButton(
                onPressed: () => controller.next(),
                child: const Text('Next'),
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.volume_up),
                  SizedBox(
                    width: 200,
                    child: Slider(
                      value: controller.volume,
                      onChanged: (value) async {
                        await controller.setVolume(value);
                        await _prefs?.setDouble('volume', controller.volume);
                        if (mounted) {
                          setState(() {});
                        }
                      },
                    ),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            controller.currentTrackDuration == Duration.zero
                ? 'Track duration: loading…'
                : 'Track duration: ${_formatDuration(controller.currentTrackDuration.inSeconds)}',
            style: TextStyle(color: Colors.white.withOpacity(0.6)),
          ),
          const Spacer(),
          Text(
            'Tip: Drop your MP3 files into assets/audio and update assets/schedule.json to cover 24 hours.',
            style: TextStyle(color: Colors.white.withOpacity(0.5)),
          ),
        ],
      ),
    );
  }

  static String _formatTime(int seconds) {
    final h = (seconds ~/ 3600).toString().padLeft(2, '0');
    final m = ((seconds % 3600) ~/ 60).toString().padLeft(2, '0');
    final s = (seconds % 60).toString().padLeft(2, '0');
    return '$h:$m:$s';
  }

  static String _formatDuration(int seconds) {
    final h = seconds ~/ 3600;
    final m = (seconds % 3600) ~/ 60;
    final s = seconds % 60;
    if (h > 0) {
      return '${h}h ${m}m ${s}s';
    }
    if (m > 0) {
      return '${m}m ${s}s';
    }
    return '${s}s';
  }
}

class _ErrorApp extends StatelessWidget {
  const _ErrorApp({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: _kAppTitle,
      home: Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: Text(
            message,
            style: const TextStyle(color: Colors.redAccent, fontSize: 18),
            textAlign: TextAlign.center,
          ),
        ),
      ),
    );
  }
}
