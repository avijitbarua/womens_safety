import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:geolocator/geolocator.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:android_intent_plus/android_intent.dart';


void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'FSR Monitor',
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: Colors.blue,
        brightness: Brightness.light,
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            foregroundColor: Colors.white,
            backgroundColor: Colors.blue,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(30),
            ),
            padding: const EdgeInsets.symmetric(
              horizontal: 24,
              vertical: 12,
            ),
          ),
        ),
      ),
      home: const BLEPage(),
    );
  }
}

class BLEPage extends StatefulWidget {
  const BLEPage({super.key});

  @override
  State<BLEPage> createState() => _BLEPageState();
}

class _BLEPageState extends State<BLEPage> with WidgetsBindingObserver {
  // BLE state
  List<ScanResult> scanResults = [];
  BluetoothDevice? connectedDevice;
  BluetoothCharacteristic? txCharacteristic;
  StreamSubscription<List<ScanResult>>? _scanSubscription;
  StreamSubscription<BluetoothAdapterState>? _adapterStateSubscription;
  StreamSubscription<BluetoothConnectionState>? _connectionStateSubscription;

  // UI state
  bool isScanning = false;
  bool isConnecting = false;
  BluetoothAdapterState _adapterState = BluetoothAdapterState.unknown;

  // Sensor data (from BLE)
  int fsr1 = 0;
  int fsr2 = 0;
  int fsr3 = 0;
  int fsr4 = 0;

  // 📍 Current location (phone GPS)
  double? currentLatitude;
  double? currentLongitude;
  bool _isGettingLocation = false;

  // UUIDs
  final Guid serviceUuid = Guid("6E400001-B5A3-F393-E0A9-E50E24DCCA9E");
  final Guid txUuid = Guid("6E400003-B5A3-F393-E0A9-E50E24DCCA9E");

  // Max ADC value (10‑bit)
  static const int maxSensorValue = 1023;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _listenToAdapterState();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _scanSubscription?.cancel();
    _adapterStateSubscription?.cancel();
    _connectionStateSubscription?.cancel();
    FlutterBluePlus.stopScan();
    super.dispose();
  }

  // -------------------------------------------------------------------------
  // BLE Helpers
  // -------------------------------------------------------------------------
  void _listenToAdapterState() {
    _adapterStateSubscription = FlutterBluePlus.adapterState.listen((state) {
      if (mounted) {
        setState(() => _adapterState = state);
      }
      if (state != BluetoothAdapterState.on) {
        FlutterBluePlus.turnOn();
      }
    });
  }

  Future<void> startScan() async {
    if (isScanning) return;

    setState(() {
      scanResults.clear();
      isScanning = true;
    });

    try {
      await FlutterBluePlus.startScan(timeout: const Duration(seconds: 5));

      _scanSubscription = FlutterBluePlus.scanResults.listen((results) {
        if (mounted) {
          setState(() {
            scanResults = results;
          });
        }
      });

      await Future.delayed(const Duration(seconds: 5));
    } catch (e) {
      _showSnackBar('Scan error: $e');
    } finally {
      if (mounted) {
        setState(() => isScanning = false);
      }
    }
  }

  Future<void> connectToDevice(BluetoothDevice device) async {
    setState(() {
      isConnecting = true;
    });

    try {
      await FlutterBluePlus.stopScan();
      await device.connect();

      _connectionStateSubscription =
          device.connectionState.listen((state) {
        if (state == BluetoothConnectionState.disconnected && mounted) {
          setState(() {
            connectedDevice = null;
            txCharacteristic = null;
          });
          _showSnackBar('Disconnected from device');
        }
      });

      List<BluetoothService> services = await device.discoverServices();

      for (var service in services) {
        if (service.uuid == serviceUuid) {
          for (var c in service.characteristics) {
            if (c.uuid == txUuid) {
              txCharacteristic = c;
              await txCharacteristic!.setNotifyValue(true);

              txCharacteristic!.lastValueStream.listen((value) {
                String data = utf8.decode(value);
                _parseSensorData(data);
              });

              if (mounted) {
                setState(() {
                  connectedDevice = device;
                });
              }
              break;
            }
          }
        }
      }

      // 📍 Once connected, automatically fetch current location
      _getCurrentLocation();

    } catch (e) {
      _showSnackBar('Connection failed: $e');
    } finally {
      if (mounted) {
        setState(() => isConnecting = false);
      }
    }
  }

  // Parse only FSR values (no location from BLE)
  void _parseSensorData(String data) {
    List<String> values = data.split(',');
    if (mounted) {
      setState(() {
        fsr1 = values.length > 0 ? int.tryParse(values[0]) ?? 0 : 0;
        fsr2 = values.length > 1 ? int.tryParse(values[1]) ?? 0 : 0;
        fsr3 = values.length > 2 ? int.tryParse(values[2]) ?? 0 : 0;
        fsr4 = values.length > 3 ? int.tryParse(values[3]) ?? 0 : 0;
      });
    }
  }

  Future<void> disconnect() async {
    try {
      await connectedDevice?.disconnect();
    } catch (e) {
      _showSnackBar('Disconnect error: $e');
    }
  }

  // -------------------------------------------------------------------------
  // 📍 Geolocator: get current location
  // -------------------------------------------------------------------------
  Future<void> _getCurrentLocation() async {
    if (_isGettingLocation) return;

    setState(() => _isGettingLocation = true);

    try {
      // Check permissions
      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.deniedForever) {
        _showSnackBar('Location permissions permanently denied');
        setState(() => _isGettingLocation = false);
        return;
      }

      // Get current position
      Position position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      );

      if (mounted) {
        setState(() {
          currentLatitude = position.latitude;
          currentLongitude = position.longitude;
        });
      }
    } catch (e) {
      _showSnackBar('Failed to get location: $e');
    } finally {
      if (mounted) {
        setState(() => _isGettingLocation = false);
      }
    }
  }

  // -------------------------------------------------------------------------
  // Google Maps Launcher
  // -------------------------------------------------------------------------

Future<void> _openMaps() async {
  if (currentLatitude == null || currentLongitude == null) {
    _showSnackBar('Location not available');
    return;
  }

  final lat = currentLatitude!;
  final lng = currentLongitude!;

  // ----- ANDROID: explicit Google Maps Intent -----
  if (Theme.of(context).platform == TargetPlatform.android) {
    try {
      const package = 'com.google.android.apps.maps';
      final intent = AndroidIntent(
        action: 'android.intent.action.VIEW',
        data: 'geo:0,0?q=$lat,$lng(Your+Location)',
        package: package,
      );
      await intent.launch();
      return; // success
    } catch (e) {
      debugPrint('Android Intent failed: $e');
      // fallback to browser
    }
  }

  // ----- iOS / Fallback: use url_launcher -----
  final Uri appleMapsUri = Uri.parse(
    'https://maps.apple.com/?ll=$lat,$lng&q=Your+Location',
  );
  final Uri webUri = Uri.parse(
    'https://www.google.com/maps/search/?api=1&query=$lat,$lng',
  );

  if (await canLaunchUrl(appleMapsUri)) {
    await launchUrl(appleMapsUri);
  } else if (await canLaunchUrl(webUri)) {
    await launchUrl(webUri);
  } else {
    _showSnackBar('Could not open maps');
  }
}

  void _showSnackBar(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    );
  }

  // -------------------------------------------------------------------------
  // UI
  // -------------------------------------------------------------------------
  bool get isConnected => connectedDevice != null && txCharacteristic != null;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      backgroundColor: colorScheme.surface,
      appBar: AppBar(
        elevation: 0,
        flexibleSpace: Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [
                colorScheme.primary,
                colorScheme.primaryContainer,
              ],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
          ),
        ),
        title: const Text(
          'FSR BLE Monitor',
          style: TextStyle(fontWeight: FontWeight.w600, letterSpacing: 0.5),
        ),
        actions: [
          if (isConnected)
            IconButton(
              icon: const Icon(Icons.bluetooth_connected),
              tooltip: 'Disconnect',
              onPressed: disconnect,
            ),
        ],
      ),
      body: Column(
        children: [
          _buildAdapterStatus(),
          Expanded(
            child: isConnected ? _buildConnectedUI() : _buildScanUI(),
          ),
        ],
      ),
      floatingActionButton: !isConnected
          ? FloatingActionButton.extended(
              onPressed: isScanning ? null : startScan,
              icon: isScanning
                  ? const SizedBox(
                      height: 20,
                      width: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Icon(Icons.refresh),
              label: Text(isScanning ? 'Scanning' : 'Scan Devices'),
              backgroundColor: colorScheme.primary,
              foregroundColor: Colors.white,
            )
          : null,
    );
  }

  Widget _buildAdapterStatus() {
    final colorScheme = Theme.of(context).colorScheme;
    bool isOn = _adapterState == BluetoothAdapterState.on;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      margin: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      decoration: BoxDecoration(
        color: isOn ? colorScheme.primaryContainer : colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(30),
      ),
      child: Row(
        children: [
          Icon(
            isOn ? Icons.bluetooth : Icons.bluetooth_disabled,
            size: 20,
            color: isOn ? colorScheme.primary : colorScheme.error,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              isOn ? 'Bluetooth is ON' : 'Bluetooth is OFF',
              style: TextStyle(
                fontWeight: FontWeight.w500,
                color: isOn ? colorScheme.primary : colorScheme.error,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // -------------------------------------------------------------------------
  // Scan UI – Fully responsive
  // -------------------------------------------------------------------------
  Widget _buildScanUI() {
    return Column(
      children: [
        const SizedBox(height: 16),
        if (scanResults.isEmpty && !isScanning)
          Expanded(
            child: Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.bluetooth_searching,
                    size: 80,
                    color: Colors.grey.shade400,
                  ),
                  const SizedBox(height: 20),
                  Text(
                    'No devices found',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          color: Colors.grey.shade600,
                        ),
                  ),
                ],
              ),
            ),
          )
        else
          Expanded(
            child: ListView.separated(
              padding: const EdgeInsets.all(16),
              itemCount: scanResults.length,
              separatorBuilder: (context, index) => const SizedBox(height: 12),
              itemBuilder: (context, index) {
                final result = scanResults[index];
                final device = result.device;
                final name = device.platformName.isNotEmpty
                    ? device.platformName
                    : 'Unknown Device';
                final address = device.remoteId.str;
                final rssi = result.rssi;

                return _DeviceTile(
                  name: name,
                  address: address,
                  rssi: rssi,
                  isConnecting: isConnecting,
                  onConnect: () => connectToDevice(device),
                );
              },
            ),
          ),
      ],
    );
  }

  // -------------------------------------------------------------------------
  // Connected UI – Now with current location card
  // -------------------------------------------------------------------------
  Widget _buildConnectedUI() {
    return Column(
      children: [
        // Device info card
        Container(
          width: double.infinity,
          margin: const EdgeInsets.all(16),
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [
                Theme.of(context).colorScheme.primary,
                Theme.of(context).colorScheme.primaryContainer,
              ],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(24),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withAlpha(20),
                blurRadius: 10,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.bluetooth, color: Colors.white),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      connectedDevice?.platformName ?? 'Device',
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                connectedDevice?.remoteId.str ?? '',
                style: const TextStyle(
                  fontSize: 12,
                  color: Colors.white70,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),

        // Sensor grid – responsive
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              int crossAxisCount = constraints.maxWidth > 600 ? 3 : 2;
              if (constraints.maxWidth > 900) crossAxisCount = 4;

              return GridView.builder(
                padding: const EdgeInsets.all(16),
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: crossAxisCount,
                  mainAxisSpacing: 16,
                  crossAxisSpacing: 16,
                  childAspectRatio: 1.0,
                ),
                itemCount: 4,
                itemBuilder: (context, index) {
                  final titles = ['FSR 1', 'FSR 2', 'FSR 3', 'FSR 4'];
                  final values = [fsr1, fsr2, fsr3, fsr4];
                  return _SensorCard(
                    title: titles[index],
                    value: values[index],
                    max: maxSensorValue,
                  );
                },
              );
            },
          ),
        ),

        // 📍 Current Location Card (phone GPS)
        _LocationCard(
          latitude: currentLatitude,
          longitude: currentLongitude,
          isGettingLocation: _isGettingLocation,
          onTap: _openMaps,
          onRefresh: _getCurrentLocation,
        ),
      ],
    );
  }
}

// -------------------------------------------------------------------------
// Custom Device Tile – responsive layout
// -------------------------------------------------------------------------
class _DeviceTile extends StatelessWidget {
  final String name;
  final String address;
  final int rssi;
  final bool isConnecting;
  final VoidCallback onConnect;

  const _DeviceTile({
    required this.name,
    required this.address,
    required this.rssi,
    required this.isConnecting,
    required this.onConnect,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final screenWidth = MediaQuery.of(context).size.width;

    return Card(
      child: Padding(
        padding: EdgeInsets.all(screenWidth > 600 ? 20 : 16),
        child: Row(
          children: [
            Container(
              width: screenWidth > 600 ? 60 : 50,
              height: screenWidth > 600 ? 60 : 50,
              decoration: BoxDecoration(
                color: colorScheme.primaryContainer,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Icon(
                Icons.devices,
                color: colorScheme.primary,
                size: screenWidth > 600 ? 30 : 24,
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    name,
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: screenWidth > 600 ? 18 : 16,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 4),
                  Wrap(
                    spacing: 12,
                    runSpacing: 4,
                    children: [
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.signal_cellular_alt,
                            size: 14,
                            color: Colors.grey.shade600,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            '$rssi dBm',
                            style: TextStyle(
                              fontSize: 12,
                              color: Colors.grey.shade600,
                            ),
                          ),
                        ],
                      ),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.location_on,
                            size: 14,
                            color: Colors.grey.shade600,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            address,
                            style: TextStyle(
                              fontSize: 12,
                              color: Colors.grey.shade600,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            ElevatedButton(
              onPressed: isConnecting ? null : onConnect,
              style: ElevatedButton.styleFrom(
                foregroundColor: Colors.white,
                backgroundColor: colorScheme.primary,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(20),
                ),
                padding: EdgeInsets.symmetric(
                  horizontal: screenWidth > 600 ? 24 : 20,
                  vertical: screenWidth > 600 ? 14 : 12,
                ),
              ),
              child: isConnecting
                  ? SizedBox(
                      width: screenWidth > 600 ? 24 : 20,
                      height: screenWidth > 600 ? 24 : 20,
                      child: const CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : Text(
                      'Connect',
                      style: TextStyle(fontSize: screenWidth > 600 ? 16 : 14),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

// -------------------------------------------------------------------------
// Sensor Card – Overflow‑proof and fully responsive
// -------------------------------------------------------------------------
class _SensorCard extends StatelessWidget {
  final String title;
  final int value;
  final int max;

  const _SensorCard({
    required this.title,
    required this.value,
    required this.max,
  });

  @override
  Widget build(BuildContext context) {
    final progress = (value / max).clamp(0.0, 1.0);
    final colorScheme = Theme.of(context).colorScheme;
    final screenWidth = MediaQuery.of(context).size.width;

    final titleFontSize = screenWidth > 600 ? 18.0 : 14.0;
    final valueFontSize = screenWidth > 600 ? 40.0 : 32.0;
    final percentageFontSize = screenWidth > 600 ? 14.0 : 12.0;
    final verticalPadding = screenWidth > 600 ? 20.0 : 12.0;

    return Card(
      child: Container(
        height: double.infinity,
        padding: EdgeInsets.all(verticalPadding),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: titleFontSize,
                    fontWeight: FontWeight.w600,
                    color: Colors.grey.shade600,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '$value',
                  style: TextStyle(
                    fontSize: valueFontSize,
                    fontWeight: FontWeight.bold,
                    color: colorScheme.primary,
                  ),
                ),
              ],
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                LinearProgressIndicator(
                  value: progress,
                  backgroundColor: colorScheme.primaryContainer,
                  color: colorScheme.primary,
                  minHeight: 8,
                  borderRadius: BorderRadius.circular(4),
                ),
                const SizedBox(height: 6),
                Text(
                  '${(progress * 100).toStringAsFixed(0)}%',
                  style: TextStyle(
                    fontSize: percentageFontSize,
                    color: Colors.grey.shade600,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// -------------------------------------------------------------------------
// 📍 Location Card – shows current phone location, tappable + refresh
// -------------------------------------------------------------------------
class _LocationCard extends StatelessWidget {
  final double? latitude;
  final double? longitude;
  final bool isGettingLocation;
  final VoidCallback onTap;
  final VoidCallback onRefresh;

  const _LocationCard({
    required this.latitude,
    required this.longitude,
    required this.isGettingLocation,
    required this.onTap,
    required this.onRefresh,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final hasLocation = latitude != null && longitude != null;

    final latStr = hasLocation
        ? latitude!.toStringAsFixed(6)
        : '—';
    final lonStr = hasLocation
        ? longitude!.toStringAsFixed(6)
        : '—';

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: Material(
        color: hasLocation
            ? colorScheme.primaryContainer.withAlpha(30)
            : Colors.grey.shade100,
        borderRadius: BorderRadius.circular(20),
        child: InkWell(
          onTap: hasLocation ? onTap : null,
          borderRadius: BorderRadius.circular(20),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
            decoration: BoxDecoration(
              border: Border.all(
                color: hasLocation
                    ? colorScheme.primary
                    : Colors.grey.shade300,
                width: 1,
              ),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Row(
              children: [
                // Icon
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: hasLocation
                        ? colorScheme.primary.withAlpha(20)
                        : Colors.grey.shade200,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(
                    Icons.location_on,
                    color: hasLocation ? colorScheme.primary : Colors.grey,
                    size: 24,
                  ),
                ),
                const SizedBox(width: 16),

                // Location text
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text(
                            'Your Location',
                            style: TextStyle(
                              fontWeight: FontWeight.w600,
                              fontSize: 16,
                              color: hasLocation
                                  ? colorScheme.primary
                                  : Colors.grey.shade700,
                            ),
                          ),
                          if (isGettingLocation) ...[
                            const SizedBox(width: 8),
                            const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                              ),
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '$latStr, $lonStr',
                        style: TextStyle(
                          fontSize: 14,
                          color: hasLocation
                              ? Colors.black87
                              : Colors.grey.shade600,
                        ),
                      ),
                    ],
                  ),
                ),

                // Actions: refresh + open maps
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (!isGettingLocation)
                      IconButton(
                        icon: Icon(Icons.refresh, size: 20),
                        color: colorScheme.primary,
                        onPressed: onRefresh,
                        tooltip: 'Refresh location',
                      ),
                    if (hasLocation)
                      IconButton(
                        icon: Icon(Icons.open_in_new, size: 20),
                        color: colorScheme.primary,
                        onPressed: onTap,
                        tooltip: 'Open in Google Maps',
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}