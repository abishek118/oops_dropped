import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:local_auth/local_auth.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'services/background_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeService();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Oops Dropped',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        primarySwatch: Colors.deepPurple,
        scaffoldBackgroundColor: const Color(0xFF121212),
        useMaterial3: true,
      ),
      home: const HomeScreen(),
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  bool _isServiceActive = false;
  bool _playSound = true;
  bool _isAlarming = false;
  bool _secureStop = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadPreferences();
    
    // Listen for alarm state from background service
    FlutterBackgroundService().on('alarm_state').listen((event) {
      if (event != null && event['is_alarming'] != null) {
        if (mounted) {
          setState(() {
            _isAlarming = event['is_alarming'];
          });
        }
      }
    });
    
    // Request initial state in case the app was opened while the alarm was already running
    FlutterBackgroundService().invoke('request_state');
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // Re-check state when returning to the app
      FlutterBackgroundService().invoke('request_state');
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _loadPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _isServiceActive = prefs.getBool('service_active') ?? false;
      _playSound = prefs.getBool('play_sound_on_fall') ?? true;
      _secureStop = prefs.getBool('secure_stop_alarm') ?? false;
    });
    
    // Check if background service is actually running
    final service = FlutterBackgroundService();
    bool isRunning = await service.isRunning();
    if (isRunning != _isServiceActive) {
      setState(() {
        _isServiceActive = isRunning;
      });
      prefs.setBool('service_active', isRunning);
    }
  }

  Future<void> _toggleService(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    final service = FlutterBackgroundService();

    if (value) {
      if (await Permission.notification.isDenied) {
        await Permission.notification.request();
      }
      await service.startService();
    } else {
      service.invoke('stopService');
    }

    setState(() {
      _isServiceActive = value;
    });
    await prefs.setBool('service_active', value);
  }

  Future<void> _toggleSound(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _playSound = value;
    });
    await prefs.setBool('play_sound_on_fall', value);
  }

  Future<void> _toggleSecureStop(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _secureStop = value;
    });
    await prefs.setBool('secure_stop_alarm', value);
  }

  Future<void> _stopAlarm() async {
    if (_secureStop) {
      try {
        final LocalAuthentication auth = LocalAuthentication();
        final bool canAuthenticateWithBiometrics = await auth.canCheckBiometrics;
        final bool canAuthenticate = canAuthenticateWithBiometrics || await auth.isDeviceSupported();

        if (canAuthenticate) {
          final bool didAuthenticate = await auth.authenticate(
            localizedReason: 'Please authenticate to stop the alarm',
            options: const AuthenticationOptions(
              stickyAuth: true,
              biometricOnly: false,
            ),
          );

          if (!didAuthenticate) {
            return;
          }
        } else {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Device lock security is not configured. Stopping alarm.')),
            );
          }
        }
      } on PlatformException catch (e) {
        debugPrint("Device authentication error: $e");
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Verification error: ${e.message ?? e.toString()}')),
          );
        }
      }
    }

    FlutterBackgroundService().invoke('stop_alarm');
    setState(() {
      _isAlarming = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _isAlarming ? Colors.white : null,
      appBar: _isAlarming ? null : AppBar(
        title: const Text('Oops Dropped', style: TextStyle(fontWeight: FontWeight.bold)),
        centerTitle: true,
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: _isAlarming ? _buildAlarmScreen() : _buildSettingsScreen(),
    );
  }

  Widget _buildAlarmScreen() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.warning_amber_rounded, size: 150, color: Colors.redAccent),
          const SizedBox(height: 32),
          const Text("FALL DETECTED", style: TextStyle(fontSize: 32, fontWeight: FontWeight.bold, color: Colors.redAccent)),
          const SizedBox(height: 48),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
              padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            ),
            onPressed: _stopAlarm,
            child: const Text("I'M OKAY - STOP ALARM", style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Colors.white)),
          )
        ],
      ),
    );
  }

  Widget _buildSettingsScreen() {
    return SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.center,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                boxShadow: _isServiceActive
                    ? [
                        BoxShadow(
                          color: Colors.greenAccent.withAlpha(76),
                          blurRadius: 25,
                          spreadRadius: 5,
                        )
                      ]
                    : [],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(60),
                child: ColorFiltered(
                  colorFilter: _isServiceActive
                      ? const ColorFilter.mode(Colors.transparent, BlendMode.multiply)
                      : const ColorFilter.matrix(<double>[
                          0.2126, 0.7152, 0.0722, 0, 0,
                          0.2126, 0.7152, 0.0722, 0, 0,
                          0.2126, 0.7152, 0.0722, 0, 0,
                          0,      0,      0,      1, 0,
                        ]),
                  child: Image.asset(
                    'assets/logo.png',
                    width: 120,
                    height: 120,
                    fit: BoxFit.cover,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 32),
            Text(
              _isServiceActive ? 'Protection Active' : 'Protection Disabled',
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.bold,
                color: _isServiceActive ? Colors.greenAccent : Colors.grey,
              ),
            ),
            const SizedBox(height: 16),
            const Text(
              'Your phone will automatically turn on the flashlight and maximize brightness if it detects a free fall.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 16, color: Colors.white70),
            ),
            const SizedBox(height: 48),
            Container(
              decoration: BoxDecoration(
                color: const Color(0xFF1E1E1E),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Column(
                children: [
                  SwitchListTile(
                    title: const Text('Background Service', style: TextStyle(fontWeight: FontWeight.bold)),
                    subtitle: const Text('Run detection in background'),
                    value: _isServiceActive,
                    activeThumbColor: Colors.greenAccent,
                    onChanged: _toggleService,
                    secondary: const Icon(Icons.settings_system_daydream),
                  ),
                  const Divider(height: 1, color: Colors.white12),
                  SwitchListTile(
                    title: const Text('Play Alarm Sound', style: TextStyle(fontWeight: FontWeight.bold)),
                    subtitle: const Text('Sound alert on fall detection'),
                    value: _playSound,
                    activeThumbColor: Colors.greenAccent,
                    onChanged: _toggleSound,
                    secondary: const Icon(Icons.volume_up),
                  ),
                  const Divider(height: 1, color: Colors.white12),
                  SwitchListTile(
                    title: const Text('Secure Stop', style: TextStyle(fontWeight: FontWeight.bold)),
                    subtitle: const Text('Require lock screen verification to stop alarm'),
                    value: _secureStop,
                    activeThumbColor: Colors.greenAccent,
                    onChanged: _toggleSecureStop,
                    secondary: const Icon(Icons.lock_outline),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
