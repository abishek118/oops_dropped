import 'dart:async';
import 'dart:io';
import 'dart:ui';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'fall_detector.dart';

Future<void> initializeService() async {
  final service = FlutterBackgroundService();

  await service.configure(
    androidConfiguration: AndroidConfiguration(
      onStart: onStart,
      autoStart: false,
      isForegroundMode: true,
      initialNotificationTitle: 'Fall Detector Active',
      initialNotificationContent: 'Monitoring for falls in the background',
    ),
    iosConfiguration: IosConfiguration(
      autoStart: false,
      onForeground: onStart,
      onBackground: onIosBackground,
    ),
  );
}

@pragma('vm:entry-point')
Future<bool> onIosBackground(ServiceInstance service) async {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();
  return true;
}

@pragma('vm:entry-point')
void onStart(ServiceInstance service) async {
  DartPluginRegistrant.ensureInitialized();
  
  if (service is AndroidServiceInstance) {
    service.on('setAsForeground').listen((event) {
      service.setAsForegroundService();
    });

    service.on('setAsBackground').listen((event) {
      service.setAsBackgroundService();
    });
  }

  service.on('stopService').listen((event) {
    service.stopSelf();
  });

  // Keep iOS alive with silent audio loop
  AudioPlayer? silentPlayer;
  if (Platform.isIOS) {
    silentPlayer = AudioPlayer();
    await silentPlayer.setVolume(0.0);
    await silentPlayer.setReleaseMode(ReleaseMode.loop);
    await silentPlayer.play(AssetSource('audio/alarm.wav'));
  }

  // Initialize Fall Detector
  final fallDetector = FallDetector(
    onAlarmStateChanged: (isActive) {
      service.invoke('alarm_state', {'is_alarming': isActive});
    },
  );
  fallDetector.startListening();

  service.on('stop_alarm').listen((event) {
    fallDetector.stopAlarm();
  });

  service.on('request_state').listen((event) {
    service.invoke('alarm_state', {'is_alarming': fallDetector.isAlarmActive});
  });

  // Keep checking if user disabled it via SharedPreferences
  Timer.periodic(const Duration(seconds: 1), (timer) async {
    final prefs = await SharedPreferences.getInstance();
    final isActive = prefs.getBool('service_active') ?? false;
    
    if (service is AndroidServiceInstance) {
      if (await service.isForegroundService()) {
        service.setForegroundNotificationInfo(
          title: "Fall Detector Active",
          content: "Monitoring for falls in the background",
        );
      }
    }

    if (!isActive) {
      fallDetector.stopListening();
      silentPlayer?.stop();
      service.stopSelf();
      timer.cancel();
    }
  });
}
