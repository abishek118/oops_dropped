import 'dart:async';
import 'dart:math';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:screen_brightness/screen_brightness.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:torch_light/torch_light.dart';

class FallDetector {
  StreamSubscription<AccelerometerEvent>? _accelerometerSubscription;
  DateTime? _fallStartTime;
  bool _isFalling = false;
  
  DateTime? _lastEventTime;
  
  // Constants for fall detection
  static const double _fallThreshold = 4.0; // Increased to 0.4g to be more forgiving during a drop
  static const int _fallDurationMs = 200; // Decreased to 200ms to catch shorter drops (like from waist height)
  static const int _maxGapMs = 1000; // Increased to 1 second to allow for default Android sensor delays

  final AudioPlayer _audioPlayer = AudioPlayer();
  final FlutterLocalNotificationsPlugin _flutterLocalNotificationsPlugin = FlutterLocalNotificationsPlugin();
  
  bool _isAlarmActive = false;
  bool get isAlarmActive => _isAlarmActive;
  Timer? _flashTimer;
  final Function(bool)? onAlarmStateChanged;

  FallDetector({this.onAlarmStateChanged}) {
    _initNotifications();
  }

  Future<void> _initNotifications() async {
    const AndroidInitializationSettings initializationSettingsAndroid =
        AndroidInitializationSettings('ic_bg_service_small');
    const DarwinInitializationSettings initializationSettingsIOS =
        DarwinInitializationSettings();
    const InitializationSettings initializationSettings = InitializationSettings(
        android: initializationSettingsAndroid,
        iOS: initializationSettingsIOS);
    await _flutterLocalNotificationsPlugin.initialize(settings: initializationSettings);
  }

  void startListening() {
    _accelerometerSubscription = accelerometerEventStream().listen((AccelerometerEvent event) {
      if (_isAlarmActive) return; // Ignore events while alarm is active
      
      double magnitude = sqrt(event.x * event.x + event.y * event.y + event.z * event.z);
      final now = DateTime.now();

      // If there's a significant gap between events (e.g., UI stutter or screen lock),
      // reset the fall timer because we can't guarantee it was a continuous fall.
      if (_lastEventTime != null && now.difference(_lastEventTime!).inMilliseconds > _maxGapMs) {
        _fallStartTime = null;
      }
      _lastEventTime = now;

      if (magnitude < _fallThreshold) {
        if (_fallStartTime == null) {
          _fallStartTime = now;
        } else {
          final duration = now.difference(_fallStartTime!).inMilliseconds;
          if (duration >= _fallDurationMs && !_isFalling) {
            _isFalling = true;
            _onFallDetected();
          }
        }
      } else {
        // Reset if we exceed the threshold
        _fallStartTime = null;
        _isFalling = false;
      }
    });
  }

  void stopListening() {
    _accelerometerSubscription?.cancel();
    _accelerometerSubscription = null;
    stopAlarm();
  }

  Future<void> _onFallDetected() async {
    print("Free fall detected! Starting continuous alarm...");
    _isAlarmActive = true;
    onAlarmStateChanged?.call(true);
    
    // 1. Wake screen via full-screen intent notification
    _triggerFullScreenIntent();

    // 2. Maximize Screen Brightness
    try {
      await ScreenBrightness().setApplicationScreenBrightness(1.0);
    } catch (e) {
      print("Could not set screen brightness: $e");
    }

    // 3. Play Alarm Sound in a loop
    try {
      final prefs = await SharedPreferences.getInstance();
      final bool playSound = prefs.getBool('play_sound_on_fall') ?? true;
      if (playSound) {
        await _audioPlayer.setReleaseMode(ReleaseMode.loop);
        await _audioPlayer.play(AssetSource('audio/alarm.wav'));
      }
    } catch (e) {
      print("Could not play alarm sound: $e");
    }

    // 4. Blink Flashlight
    _startFlashing();
  }

  Future<void> _triggerFullScreenIntent() async {
    const AndroidNotificationDetails androidPlatformChannelSpecifics =
        AndroidNotificationDetails(
      'fall_alarm_channel',
      'Fall Alarms',
      channelDescription: 'Emergency notifications for falls',
      importance: Importance.max,
      priority: Priority.high,
      fullScreenIntent: true,
      category: AndroidNotificationCategory.alarm,
      visibility: NotificationVisibility.public,
    );
    const NotificationDetails platformChannelSpecifics =
        NotificationDetails(android: androidPlatformChannelSpecifics);
        
    await _flutterLocalNotificationsPlugin.show(
      id: 0,
      title: 'Fall Detected!',
      body: 'Are you okay? Please confirm.',
      notificationDetails: platformChannelSpecifics,
    );
  }

  void _startFlashing() async {
    bool isTorchOn = false;
    try {
      final isTorchAvailable = await TorchLight.isTorchAvailable();
      if (!isTorchAvailable) return;
      
      _flashTimer = Timer.periodic(const Duration(milliseconds: 500), (timer) async {
        if (!isTorchOn) {
          await TorchLight.enableTorch().catchError((_) {});
          isTorchOn = true;
        } else {
          await TorchLight.disableTorch().catchError((_) {});
          isTorchOn = false;
        }
      });
    } catch (e) {
      print("Could not blink torch: $e");
    }
  }

  Future<void> stopAlarm() async {
    _isAlarmActive = false;
    _isFalling = false;
    _fallStartTime = null;
    onAlarmStateChanged?.call(false);

    // Stop flash
    _flashTimer?.cancel();
    _flashTimer = null;
    try { await TorchLight.disableTorch(); } catch (_) {}

    // Stop audio
    await _audioPlayer.stop();

    // Reset screen brightness
    try { await ScreenBrightness().resetApplicationScreenBrightness(); } catch (_) {}
    
    // Cancel notification
    await _flutterLocalNotificationsPlugin.cancel(id: 0);
  }
}
