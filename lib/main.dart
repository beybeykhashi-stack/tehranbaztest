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
  final prefs = await SharedPreferences.getInstance();
  final defaultMusicDir = p.join(Directory.current.path, 'assets', 'audio');
  final musicDirectory = prefs.getString('music_directory') ?? defaultMusicDir;
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

  runApp(ChronoAppLoader(prefs: prefs, musicDirectory: musicDirectory));
}

class ChronoAppLoader extends StatefulWidget {
  const ChronoAppLoader({super.key, required this.prefs, required this.musicDirectory});

  final SharedPreferences prefs;
  final String musicDirectory;

  @override
  State<ChronoAppLoader> createState() => _ChronoAppLoaderState();
}

class _ChronoAppLoaderState extends State<ChronoAppLoader> {
  late Future<DaySchedule> _scheduleFuture;

  @override
  void initState() {
    super.initState();
    _scheduleFuture = _loadSchedule();
  }

  Future<DaySchedule> _loadSchedule() async {
    try {
      return await loadScheduleFromFolder(widget.musicDirectory, widget.prefs);
    } catch (error, stack) {
      debugPrint('Schedule error: $error\n$stack');
      rethrow;
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<DaySchedule>(
      future: _scheduleFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const MaterialApp(
            title: _kAppTitle,
            home: Scaffold(
              backgroundColor: Colors.black,
              body: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircularProgressIndicator(),
                    SizedBox(height: 12),
                    Text('Loading schedule…', style: TextStyle(color: Colors.white70)),
                  ],
                ),
              ),
            ),
          );
        }

        if (snapshot.hasError || !snapshot.hasData) {
          final message = snapshot.error?.toString() ?? 'Unknown schedule error';
          return _ErrorApp(message: 'Failed to load schedule: $message');
        }

        return ChronoApp(
          schedule: snapshot.data!,
          prefs: widget.prefs,
          musicDirectory: widget.musicDirectory,
        );
      },
    );
  }
}

class ChronoApp extends StatelessWidget {
  const ChronoApp({super.key, required this.schedule, required this.prefs, required this.musicDirectory});

  final DaySchedule schedule;
  final SharedPreferences prefs;
  final String musicDirectory;

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
        home: HomePage(prefs: prefs, initialDirectory: musicDirectory),
      ),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key, this.prefs, this.initialDirectory});

  final SharedPreferences? prefs;
  final String? initialDirectory;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WindowListener {
  StreamSubscription<DateTime>? _tickSubscription;
  late final DateFormat _timeFormat;
  late SharedPreferences _prefs;
  DateTime _now = DateTime.now();
  late String _musicDirectory;
  final TextEditingController _folderController = TextEditingController();
  final Map<String, TextEditingController> _startControllers = {};
  final Map<String, FocusNode> _startFocusNodes = {};

  final SystemTray _systemTray = SystemTray();
  final Menu _trayMenu = Menu();
  String? _trayIconPath;

  @override
  void initState() {
    super.initState();
    _timeFormat = DateFormat('HH:mm:ss');
    windowManager.addListener(this);
    _musicDirectory = widget.initialDirectory ?? p.join(Directory.current.path, 'assets', 'audio');
    _folderController.text = _musicDirectory;
    WidgetsBinding.instance.addPostFrameCallback((_) => _initialize());
  }

  Future<void> _initialize() async {
    final controller = Provider.maybeOf<PlayerController>(context, listen: false);
    if (controller == null) {
      debugPrint('HomePage requires a PlayerController provider; skipping init.');
      return;
    }
    _prefs = widget.prefs ?? await SharedPreferences.getInstance();
    final storedVolume = _prefs.getDouble('volume');
    if (storedVolume != null) {
      await controller.setVolume(storedVolume);
    }
    await controller.playForNow(DateTime.now());
    _tickSubscription = alignedSecondTicks().listen((now) {
      controller.resyncIfDrifted(now);
      if (mounted) {
        setState(() {
          _now = now;
        });
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
    _folderController.dispose();
    for (final controller in _startControllers.values) {
      controller.dispose();
    }
    for (final node in _startFocusNodes.values) {
      node.dispose();
    }
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
    final controller = _maybeController(context);
    if (controller == null) {
      return const Scaffold(
        backgroundColor: Color(0xFF101218),
        body: Center(
          child: Text(
            'No PlayerController found. Wrap HomePage in a ChangeNotifierProvider.',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    final schedule = controller.schedule;
    final now = _now;
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

  PlayerController? _maybeController(BuildContext context) {
    try {
      return context.watch<PlayerController>();
    } on ProviderNotFoundException {
      return null;
    }
  }

  Widget _buildScheduleList(DaySchedule schedule, int currentIndex) {
    _syncStartControllers(schedule);
    return SizedBox(
      width: 320,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Schedule',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _folderController,
                  decoration: InputDecoration(
                    labelText: 'Music folder',
                    suffixIcon: IconButton(
                      icon: const Icon(Icons.refresh),
                      onPressed: _reloadFromFolder,
                    ),
                  ),
                  onSubmitted: (_) => _reloadFromFolder(),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    IconButton(
                      tooltip: 'Sort by name',
                      onPressed: () => _sortSchedule(byName: true),
                      icon: const Icon(Icons.sort_by_alpha),
                    ),
                    IconButton(
                      tooltip: 'Sort by start time',
                      onPressed: () => _sortSchedule(byName: false),
                      icon: const Icon(Icons.access_time),
                    ),
                  ],
                ),
              ],
            ),
          ),
          Expanded(
            child: ReorderableListView.builder(
              itemCount: schedule.entries.length,
              onReorder: _reorderEntries,
              itemBuilder: (context, index) {
                final entry = schedule.entries[index];
                final isCurrent = index == currentIndex;
                final entryKey = _entryKey(entry);
                final controller = _startControllers[entryKey]!;
                final focusNode = _startFocusNodes[entryKey]!;
                return Container(
                  key: ValueKey(entryKey),
                  color: isCurrent ? Colors.white10 : Colors.transparent,
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 90,
                        child: TextField(
                          controller: controller,
                          focusNode: focusNode,
                          decoration: const InputDecoration(labelText: 'HH:mm:ss'),
                          onSubmitted: (value) => _updateStart(entry, value),
                          onEditingComplete: () => _updateStart(entry, controller.text),
                          keyboardType: TextInputType.datetime,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          p.basename(entry.file),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const Icon(Icons.drag_indicator),
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
                        await _prefs.setDouble('volume', controller.volume);
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

  Future<void> _reloadFromFolder() async {
    try {
      final newDirectory = _folderController.text.trim();
      if (newDirectory.isEmpty) {
        return;
      }
      _musicDirectory = newDirectory;
      await _prefs.setString('music_directory', _musicDirectory);
      final schedule = await loadScheduleFromFolder(_musicDirectory, _prefs);
      await context.read<PlayerController>().updateSchedule(schedule);
      if (mounted) {
        setState(() {});
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to load folder: $e')),
        );
      }
    }
  }

  Future<void> _sortSchedule({required bool byName}) async {
    final controller = context.read<PlayerController>();
    final entries = [...controller.schedule.entries];
    final orderedFiles = entries.map((e) => e.file).toList();
    if (byName) {
      orderedFiles.sort((a, b) => p.basename(a).compareTo(p.basename(b)));
    }
    final updated = await _buildScheduleForOrder(orderedFiles);
    await controller.updateSchedule(updated);
    await persistScheduleToFile(updated, _prefs, _musicDirectory);
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _reorderEntries(int oldIndex, int newIndex) async {
    final controller = context.read<PlayerController>();
    final entries = [...controller.schedule.entries];
    if (newIndex > oldIndex) {
      newIndex -= 1;
    }
    final item = entries.removeAt(oldIndex);
    entries.insert(newIndex, item);
    final orderedFiles = entries.map((e) => e.file).toList();
    final updated = await _buildScheduleForOrder(orderedFiles);
    await controller.updateSchedule(updated);
    await persistScheduleToFile(updated, _prefs, _musicDirectory);
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _updateStart(ScheduleEntry entry, String value) async {
    final parts = value.split(':').map((p) => p.trim()).where((p) => p.isNotEmpty).toList();
    if (parts.length != 3) {
      _showParseError();
      return;
    }
    try {
      final hours = int.parse(parts[0]);
      final minutes = int.parse(parts[1]);
      final seconds = int.parse(parts[2]);
      if (hours < 0 || hours > 23 || minutes < 0 || minutes > 59 || seconds < 0 || seconds > 59) {
        _showParseError();
        return;
      }
      final start = hours * 3600 + minutes * 60 + seconds;
      if (start >= DaySchedule.secondsPerDay) {
        _showParseError();
        return;
      }
      final controller = context.read<PlayerController>();
      final entries = controller.schedule.entries
          .map((e) => e == entry ? e.copyWith(startSec: start) : e)
          .toList();
      final updated = DaySchedule.fromEntries(entries);
      await controller.updateSchedule(updated);
      await persistScheduleToFile(updated, _prefs, _musicDirectory);
      if (mounted) {
        setState(() {});
      }
    } catch (_) {
      _showParseError();
    }
  }

  Future<DaySchedule> _buildScheduleForOrder(List<String> orderedFiles) async {
    return buildSequentialSchedule(orderedFiles);
  }

  void _syncStartControllers(DaySchedule schedule) {
    final expectedKeys = schedule.entries.map(_entryKey).toSet();
    final staleKeys = _startControllers.keys.where((k) => !expectedKeys.contains(k)).toList();
    for (final key in staleKeys) {
      _startControllers.remove(key)?.dispose();
      _startFocusNodes.remove(key)?.dispose();
    }

    for (final entry in schedule.entries) {
      final key = _entryKey(entry);
      final controller = _startControllers.putIfAbsent(
        key,
        () => TextEditingController(text: _formatHoursMinutesSeconds(entry.startSec)),
      );
      final focusNode = _startFocusNodes.putIfAbsent(key, () => FocusNode());
      final expected = _formatHoursMinutesSeconds(entry.startSec);
      if (!focusNode.hasFocus && controller.text != expected) {
        controller.text = expected;
      }
    }
  }

  void _showParseError() {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Enter start time as HH:mm:ss')),
    );
  }

  String _formatHoursMinutesSeconds(int seconds) {
    final hours = seconds ~/ 3600;
    final minutes = (seconds % 3600) ~/ 60;
    final secs = seconds % 60;
    return '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:${secs.toString().padLeft(2, '0')}';
  }

  String _entryKey(ScheduleEntry entry) => '${entry.file}|${entry.startSec}';
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
