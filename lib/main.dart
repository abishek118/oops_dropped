import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:local_auth/local_auth.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:screen_brightness/screen_brightness.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
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

  final TextEditingController _phone1Controller = TextEditingController();
  final TextEditingController _phone2Controller = TextEditingController();
  String _emergencyNumber1 = '';
  String _emergencyNumber2 = '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadPreferences();
    
    // Listen for alarm state from background service
    FlutterBackgroundService().on('alarm_state').listen((event) {
      if (event != null && event['is_alarming'] != null) {
        final bool shouldAlarm = event['is_alarming'];
        if (mounted) {
          setState(() {
            _isAlarming = shouldAlarm;
          });
          
          // Maximize or reset screen brightness in the foreground UI
          if (shouldAlarm) {
            try { ScreenBrightness().setApplicationScreenBrightness(1.0); } catch (_) {}
          } else {
            try { ScreenBrightness().resetApplicationScreenBrightness(); } catch (_) {}
          }
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
    _phone1Controller.dispose();
    _phone2Controller.dispose();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _loadPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _isServiceActive = prefs.getBool('service_active') ?? false;
      _playSound = prefs.getBool('play_sound_on_fall') ?? true;
      _secureStop = prefs.getBool('secure_stop_alarm') ?? false;
      _emergencyNumber1 = prefs.getString('emergency_number_1') ?? '';
      _emergencyNumber2 = prefs.getString('emergency_number_2') ?? '';
      _phone1Controller.text = _emergencyNumber1;
      _phone2Controller.text = _emergencyNumber2;
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

  Future<void> _saveEmergencyNumber(int index, String value) async {
    final prefs = await SharedPreferences.getInstance();
    if (index == 1) {
      _emergencyNumber1 = value;
      await prefs.setString('emergency_number_1', value);
    } else {
      _emergencyNumber2 = value;
      await prefs.setString('emergency_number_2', value);
    }
  }

  Future<void> _callNumber(String number) async {
    final Uri launchUri = Uri(
      scheme: 'tel',
      path: number.replaceAll(RegExp(r'\s+'), ''),
    );
    try {
      if (await canLaunchUrl(launchUri)) {
        await launchUrl(launchUri);
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Could not launch the phone dialer.')),
          );
        }
      }
    } catch (e) {
      debugPrint('Error launching dialer: $e');
    }
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

    // Reset screen brightness when alarm stops
    try { ScreenBrightness().resetApplicationScreenBrightness(); } catch (_) {}

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
      child: SingleChildScrollView(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.warning_amber_rounded, size: 120, color: Colors.redAccent),
            const SizedBox(height: 24),
            const Text("FALL DETECTED", style: TextStyle(fontSize: 32, fontWeight: FontWeight.bold, color: Colors.redAccent)),
            const SizedBox(height: 32),
            
            if (_emergencyNumber1.isNotEmpty || _emergencyNumber2.isNotEmpty) ...[
              const Text(
                "EMERGENCY CONTACTS",
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.black54),
              ),
              const SizedBox(height: 12),
              if (_emergencyNumber1.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 6),
                  child: ElevatedButton.icon(
                    icon: const Icon(Icons.call, color: Colors.white),
                    label: Text("CALL: $_emergencyNumber1", style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 18)),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.green,
                      minimumSize: const Size(280, 56),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    onPressed: () => _callNumber(_emergencyNumber1),
                  ),
                ),
              if (_emergencyNumber2.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 6),
                  child: ElevatedButton.icon(
                    icon: const Icon(Icons.call, color: Colors.white),
                    label: Text("CALL: $_emergencyNumber2", style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 18)),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.green,
                      minimumSize: const Size(280, 56),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    onPressed: () => _callNumber(_emergencyNumber2),
                  ),
                ),
              const SizedBox(height: 32),
            ],
            
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red,
                padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 20),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              ),
              onPressed: _stopAlarm,
              child: const Text("I'M OKAY - STOP ALARM", style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Colors.white)),
            )
          ],
        ),
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
            const SizedBox(height: 24),
            const Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'Emergency Contacts',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white70),
              ),
            ),
            const SizedBox(height: 12),
            Container(
              decoration: BoxDecoration(
                color: const Color(0xFF1E1E1E),
                borderRadius: BorderRadius.circular(16),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Column(
                children: [
                  TextField(
                    controller: _phone1Controller,
                    decoration: const InputDecoration(
                      labelText: 'Emergency Contact 1',
                      icon: Icon(Icons.phone, color: Colors.greenAccent),
                      border: InputBorder.none,
                      labelStyle: TextStyle(color: Colors.white54),
                    ),
                    style: const TextStyle(color: Colors.white),
                    keyboardType: TextInputType.phone,
                    onChanged: (val) => _saveEmergencyNumber(1, val),
                  ),
                  const Divider(height: 1, color: Colors.white12),
                  TextField(
                    controller: _phone2Controller,
                    decoration: const InputDecoration(
                      labelText: 'Emergency Contact 2',
                      icon: Icon(Icons.phone, color: Colors.greenAccent),
                      border: InputBorder.none,
                      labelStyle: TextStyle(color: Colors.white54),
                    ),
                    style: const TextStyle(color: Colors.white),
                    keyboardType: TextInputType.phone,
                    onChanged: (val) => _saveEmergencyNumber(2, val),
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
