import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:kafkabr/kafka.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;
import 'package:latlong2/latlong.dart';
import 'package:vpn_info/vpn_info.dart';
import 'package:flutter_map_location_marker/flutter_map_location_marker.dart';
import 'package:flutter/foundation.dart';
import 'dart:math';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final cameras = await availableCameras();
  runApp(MyApp(cameras));
}

class MyApp extends StatelessWidget {
  final List<CameraDescription> cameras;

  MyApp(this.cameras);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Kafka Consumer and Producer App',
      theme: ThemeData(
        primarySwatch: Colors.blue,
      ),
      home: PhotoScreen(cameras),
    );
  }
}

class PhotoScreen extends StatefulWidget {
  final List<CameraDescription> cameras;

  PhotoScreen(this.cameras);

  @override
  State<PhotoScreen> createState() => _PhotoScreenState();
}

class _PhotoScreenState extends State<PhotoScreen> {
  CameraController? controller;
  bool isCapturing = false;
  Timer? _timer;
  Timer? _locationTimer;
  final String topicNameProducer = 'test-pictures-flutter';
  late String topicNameConsumer;
  KafkaSession? session;
  Producer? producer;
  Consumer? consumer;
  String? ipAddress;
  SendPort? isolateSendPort;
  double speed = 0.0;
  double heading = 0.0;
  LatLng currentLocation = LatLng(46.554649, 15.645881);
  LatLng? selectedLocation;
  StreamSubscription<Position>? _positionStreamSubscription;
  bool _isStreaming = false;
  StreamSubscription<MessageEnvelope>? _consumerSubscription;
  List<LatLng> routePoints = [];
  Map<String, int> trafficSigns = {
    '10': 0, '100': 1, '120': 2, '20': 3, '30': 4, '30-': 5, '40': 6, '40-': 7, '50': 8, '50-': 9, '60': 10, '60-': 11, '70': 12, '70-': 13, '80': 14, '80-': 15, 'delo_na_cestiscu': 16, 'kolesarji_na_cestiscu': 17, 'konec_omejitev': 18, 'odvzem_prednosti': 19, 'otroci_na_cestiscu': 20, 'prednost': 21, 'prehod_za_pesce': 22, 'stop': 23, 'unknown': 24
  };
  final MapController mapController = MapController();
  Position? _lastPosition;
  double _zoomLevel = 17.0;
  String? trafficSign;
  List<String> trafficSignsToShow = [];
  List<String> previousTrafficSigns = [];
  double widthCircle = 0;
  List<Marker> trafficSignMarkers = [];
  int frameCounter = 0;
  Map<String, LatLng> receivedTrafficSigns = {};

  @override
  void initState() {
    super.initState();
    _initializeCamera();
    _initializeKafka();
    _startKafkaConsumer();
    _initializeIsolate();
    _initializeLocationUpdates();
  }

  void _initializeLocationUpdates() {
    _positionStreamSubscription = Geolocator.getPositionStream(
      locationSettings: LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 1,
      ), // Receives updates every meter
    ).listen((Position position) {
      if (_lastPosition != null) {
        final distance = Geolocator.distanceBetween(
          _lastPosition!.latitude,
          _lastPosition!.longitude,
          position.latitude,
          position.longitude,
        );
        final time = position.timestamp!.difference(_lastPosition!.timestamp!).inSeconds;
        if (time > 0) {
          setState(() {
            speed = distance / time;
          });
        }
      }
      _lastPosition = position;
      currentLocation = LatLng(position.latitude, position.longitude);
      heading = position.heading;
      _updateTrafficSignMarkers();
    });
  }

  void _updateTrafficSignMarkers() {
    trafficSignMarkers.removeWhere((marker) {
      final distance = Geolocator.distanceBetween(
        currentLocation.latitude,
        currentLocation.longitude,
        marker.point.latitude,
        marker.point.longitude,
      );
      return distance > 50;
    });

    // Add new markers for current traffic signs
    if (trafficSignsToShow.isNotEmpty && trafficSignsToShow != previousTrafficSigns) {
      previousTrafficSigns = List.from(trafficSignsToShow);

      for (var sign in trafficSignsToShow) {
        final signIndex = trafficSigns[sign] ?? trafficSigns['unknown']!;
        final signImage = AssetImage("assets/${sign}.png");
        final newSignLocation = _calculateNewSignLocation();

        if (!_isSignInRadius(sign, newSignLocation)) {
          trafficSignMarkers.add(
            Marker(
              width: 30.0,
              height: 30.0,
              point: newSignLocation,
              builder: (ctx) => Container(
                child: Image(image: signImage),
              ),
            ),
          );
          receivedTrafficSigns[sign] = newSignLocation;
        }
      }
    }
  }

  bool _isSignInRadius(String sign, LatLng location) {
    if (receivedTrafficSigns.containsKey(sign)) {
      final existingLocation = receivedTrafficSigns[sign]!;
      final distance = Geolocator.distanceBetween(
        existingLocation.latitude,
        existingLocation.longitude,
        location.latitude,
        location.longitude,
      );
      return distance < 10.0;
    }
    return false;
  }

  LatLng _calculateNewSignLocation() {
    const double distanceInMeters = 10.0;
    const double degreesToRadians = 0.0174533;
    final double angularDistance = distanceInMeters / 6371000.0;

    final double latitudeRadians = currentLocation.latitude * degreesToRadians;
    final double longitudeRadians = currentLocation.longitude * degreesToRadians;

    final double bearingRadians = heading * degreesToRadians;

    final double newLatitudeRadians = asin(
      sin(latitudeRadians) * cos(angularDistance) +
          cos(latitudeRadians) * sin(angularDistance) * cos(bearingRadians),
    );

    final double newLongitudeRadians = longitudeRadians +
        atan2(
          sin(bearingRadians) * sin(angularDistance) * cos(latitudeRadians),
          cos(angularDistance) - sin(latitudeRadians) * sin(newLatitudeRadians),
        );

    final double newLatitude = newLatitudeRadians / degreesToRadians;
    final double newLongitude = newLongitudeRadians / degreesToRadians;

    return LatLng(newLatitude, newLongitude);
  }

  @override
  void dispose() {
    _stopImageStream();
    controller?.dispose();
    _timer?.cancel();
    _locationTimer?.cancel();
    session?.close();
    _positionStreamSubscription?.cancel();
    _consumerSubscription?.cancel();
    super.dispose();
  }

  Future<void> _initializeCamera() async {
    try {
      controller = CameraController(
        widget.cameras[0],
        ResolutionPreset.max,
        enableAudio: false,
      );
      await controller!.initialize();
      if (mounted) {
        setState(() {});
        _startImageStream();
      }
    } catch (e) {
      _showError("Error initializing camera: $e");
    }
  }

  void _startImageStream() {
    if (!_isStreaming && controller != null && controller!.value.isInitialized) {
      _isStreaming = true;
      controller!.startImageStream((CameraImage image) {
        frameCounter++;
        if (isCapturing && frameCounter % 30 == 0) {
          _processCameraImage(image);
          frameCounter = 0;
        }
      });
    }
  }

  void _stopImageStream() {
    if (_isStreaming && controller != null && controller!.value.isInitialized) {
      controller!.stopImageStream();
      _isStreaming = false;
    }
  }

  Future<void> _initializeKafka() async {
    try {
      var host = ContactPoint("10.8.2.2", 9092);
      session = KafkaSession([host]);
      producer = Producer(session!, 1, 1000);
      ipAddress = await getConnectedVpnAddresses();

      _showPopup("VPN IP Address: $ipAddress");
    } catch (e) {
      _showError("Error initializing Kafka: $e");
    }
  }

  Future<void> _initializeIsolate() async {
    final receivePort = ReceivePort();
    isolateSendPort = await Isolate.spawn(isolateEntryPoint, receivePort.sendPort).then((isolate) => receivePort.first) as SendPort;
  }

  static void isolateEntryPoint(SendPort sendPort) async {
    final receivePort = ReceivePort();
    sendPort.send(receivePort.sendPort);

    await for (final message in receivePort) {
      final CameraImage image = message[0];
      final SendPort replyPort = message[1];

      final Uint8List compressedImage = await _convertAndCompressImage(image);
      replyPort.send(compressedImage);
    }
  }

  static Future<Uint8List> _convertAndCompressImage(CameraImage image) async {
    final int width = image.width;
    final int height = image.height;
    final int uvRowStride = image.planes[1].bytesPerRow;
    final int uvPixelStride = image.planes[1].bytesPerPixel!;
    final img.Image imgImage = img.Image(width: width, height: height);

    for (int x = 0; x < width; x++) {
      for (int y = 0; y < height; y++) {
        final int uvIndex = uvPixelStride * (x >> 1) + uvRowStride * (y >> 1);
        final int index = y * width + x;

        final int yp = image.planes[0].bytes[index];
        final int up = image.planes[1].bytes[uvIndex];
        final int vp = image.planes[2].bytes[uvIndex];

        final int r = (yp + (vp - 128) * 1.402).clamp(0, 255).toInt();
        final int g = (yp - (up - 128) * 0.34414 - (vp - 128) * 0.71414).clamp(0, 255).toInt();
        final int b = (yp + (up - 128) * 1.772).clamp(0, 255).toInt();

        imgImage.setPixel(x, y, img.ColorUint8.rgb(r, g, b));
      }
    }

    final img.Image resizedImage = img.copyResize(imgImage, width: 1080);
    return Uint8List.fromList(img.encodeJpg(resizedImage, quality: 90)); // v bistvu, če je 100 nič ne compresa
  }

  void _processCameraImage(CameraImage image) async {
    if (!isCapturing) {
      return;
    }

    final responsePort = ReceivePort();
    isolateSendPort?.send([image, responsePort.sendPort]);

    final Uint8List compressedImage = await responsePort.first;
    await sendImageToKafka(compressedImage);

    compressedImage.clear();

    await Future.delayed(Duration(seconds: 0));
    if (isCapturing) {
      _startImageStream();
    }
  }

  Future<void> sendImageToKafka(Uint8List imageBytes) async {
    if (producer == null) {
      _showError("Kafka producer is not initialized.");
      return;
    }

    try {
      Position position = await _determinePosition();
      final Map<String, dynamic> message = {
        "IP": ipAddress,
        "Image": imageBytes.toList(),
        "Position": {
          "latitude": position.latitude,
          "longitude": position.longitude,
          "altitude": position.altitude,
          "accuracy": position.accuracy,
          "speed_accuracy": position.speedAccuracy,
        },
        "Time": DateTime.now().toIso8601String(),
        "Heading": position.heading,
        "Speed": "${speed.toString()} m/s"
      };

      var kafkaMessage = Message(
        jsonEncode(message).codeUnits,
        attributes: MessageAttributes(),
        key: 'image_key'.codeUnits,
      );

      var envelope = ProduceEnvelope(
        topicNameProducer,
        0,
        [kafkaMessage],
      );

      // Handle the produce operation asynchronously
      producer!.produce([envelope]).then((result) {
        print(result.hasRetriableErrors);
        if (result.errors.isNotEmpty) {
          _showError("Error sending image to Kafka: ${result.errors}");
        } else {
          print("Image sent to Kafka.");
        }
      }).catchError((e) {
        _showError("Exception sending image to Kafka: $e");
      }).whenComplete(() {
        // Complete the completer to allow the next send operation
      });
    } catch (e) {
      _showError("Exception preparing image for Kafka: $e");
    }
  }

  Future<Position> _determinePosition() async {
    bool serviceEnabled;
    LocationPermission permission;

    serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      return Future.error(
          'Location services are disabled. Please enable them in settings.');
    }

    permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) {
        return Future.error(
            'Location permissions are denied. Please grant them in settings.');
      }
    }

    if (permission == LocationPermission.deniedForever) {
      return Future.error(
          'Location permissions are permanently denied. Please enable them in settings.');
    }

    return await Geolocator.getCurrentPosition();
  }

  void _startKafkaConsumer() async {
    if (session == null) {
      _showError("Kafka session is not initialized.");
      return;
    }

    String? vpnAddress = await getConnectedVpnAddresses();
    if (vpnAddress == null) {
      _showError("Failed to get VPN IP address.");
      return;
    }

    ipAddress = vpnAddress;
    topicNameConsumer = ipAddress!;

    var group = ConsumerGroup(session!, 'myConsumerGroup');
    var topics = {topicNameConsumer: {0}};

    try {
      consumer = Consumer(session!, group, topics, 100, 1);
      _consumerSubscription = consumer!.consume().listen((MessageEnvelope envelope) {
        try {
          var jsonString = String.fromCharCodes(envelope.message.value);

          var data = jsonDecode(jsonString);

          String datetime = data['DateTime'];
          String result = data['Result'];

          setState(() {
            List<String> results = result.contains(',') ? result.split(',') : [result];
            trafficSignsToShow = results.map((r) {
              return trafficSigns.keys.firstWhere(
                    (key) => trafficSigns[key].toString() == r.trim(),
                orElse: () => "unknown",
              );
            }).toList();
          });

          _updateTrafficSignMarkers();

          envelope.commit('metadata');
        } catch (e) {
          _showError("Error processing message: $e");
          print("Error processing message: $e");
        }
      }, onError: (error) {
        _showError("Error consuming message: $error");
        print("Error consuming message: $error");
      });
    } catch (e) {
      _showError("Failed to start Kafka consumer: $e");
      print("Failed to start Kafka consumer: $e");
    }
  }

  Future<String?> getConnectedVpnAddresses() async {
    try {
      final networkInterfaces = await NetworkInterface.list(
        includeLoopback: false,
        type: InternetAddressType.any,
      );

      final vpnPatterns = ["tun", "tap", "ppp", "pptp", "l2tp", "ipsec", "vpn"];
      for (var interface in networkInterfaces) {
        if (vpnPatterns.any((pattern) => interface.name.toLowerCase().contains(pattern))) {
          if (interface.addresses.isNotEmpty) {
            return interface.addresses.first.address;
          }
        }
      }
      return null;
    } catch (e) {
      print("Error getting VPN IP Address using NetworkInterface: $e");
      return null;
    }
  }

  void _showPopup(String message) {
    showDialog(
      context: context,
      builder: (context) {
        Future.delayed(Duration(seconds: 3), () {
          Navigator.of(context).pop(true);
        });
        return AlertDialog(
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(height: 20),
              Text("The string is ${message}"),
            ],
          ),
        );
      },
    );
  }

  void _showPopupImage(Uint8List imageData) {
    showDialog(
      context: context,
      builder: (context) {
        Future.delayed(Duration(seconds: 3), () {
          Navigator.of(context).pop(true);
        });
        return AlertDialog(
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(height: 20),
              Image.memory(imageData),
            ],
          ),
        );
      },
    );
  }

  void _showError(String message) {
    final snackBar = SnackBar(
      content: Text(message),
      backgroundColor: Colors.red,
    );
    ScaffoldMessenger.of(context).showSnackBar(snackBar);
  }

  Future<List<LatLng>> searchPlaces(String query) async {
    final url = Uri.parse('https://nominatim.openstreetmap.org/search?q=$query&format=json&addressdetails=1&limit=5');
    final response = await http.get(url);
    if (response.statusCode == 200) {
      final List data = json.decode(response.body);
      if (data.isNotEmpty) {
        return data.map((place) => LatLng(double.parse(place['lat']), double.parse(place['lon']))).toList();
      }
    }
    return [];
  }

  Future<List<LatLng>> getDirections(LatLng start, LatLng end) async {
    final apiKey = '5b3ce3597851110001cf6248cb432fbcfae849e9b27a5713d89c72a5';
    final url = Uri.parse('https://api.openrouteservice.org/v2/directions/driving-car?api_key=$apiKey&start=${start.longitude},${start.latitude}&end=${end.longitude},${end.latitude}');
    final response = await http.get(url);
    if (response.statusCode == 200) {
      final data = json.decode(response.body);
      final List<LatLng> route = [];
      for (var point in data['features'][0]['geometry']['coordinates']) {
        route.add(LatLng(point[1], point[0]));
      }
      return route;
    }
    return [];
  }

  void _onPlaceSelected(LatLng place) async {
    setState(() {
      selectedLocation = place;
      mapController.move(place, 17.0); // Move the map to the place with a zoom level of 15
    });
    final directions = await getDirections(currentLocation, place);
    setState(() {
      routePoints = directions;
    });
  }

  double _calculateSize() {
    int baseSize = 100;
    int zoomAdjustment = (_zoomLevel - 17).toInt() * 10;
    return (baseSize + zoomAdjustment).clamp(10, 200).toDouble(); // Adjust 200 if you want a different max size
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Scaffold(
        body: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(8.0),
              child: buildSearchBar(),
            ),
            Expanded(
              child: LayoutBuilder(
                builder: (BuildContext context, BoxConstraints constraints) {
                  return Stack(
                    children: [
                      Positioned.fill(
                        child: FlutterMap(
                          mapController: mapController,
                          options: MapOptions(
                            zoom: _zoomLevel,
                          ),
                          children: [
                            TileLayer(
                              urlTemplate: "https://{s}.basemaps.cartocdn.com/light_all/{z}/{x}/{y}.png",
                              subdomains: ['a', 'b', 'c'],
                            ),
                            if (selectedLocation != null)
                              MarkerLayer(
                                markers: [
                                  Marker(
                                    width: 80.0,
                                    height: 80.0,
                                    point: selectedLocation!,
                                    builder: (ctx) => Container(
                                      child: Icon(
                                        Icons.location_on,
                                        size: 40.0,
                                        color: Colors.red,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            if (routePoints.isNotEmpty)
                              PolylineLayer(
                                polylines: [
                                  Polyline(
                                    points: routePoints,
                                    color: Colors.blue,
                                    strokeWidth: 4.0,
                                  ),
                                ],
                              ),
                            CurrentLocationLayer(
                              followOnLocationUpdate: FollowOnLocationUpdate.always,
                              turnOnHeadingUpdate: TurnOnHeadingUpdate.always,
                              style: LocationMarkerStyle(
                                marker: Stack(
                                  alignment: Alignment.center,
                                  children: [
                                    Container(
                                      width: _calculateSize(),
                                      height: _calculateSize(),
                                      decoration: BoxDecoration(
                                        shape: BoxShape.circle,
                                        color: Colors.blue.withOpacity(0.1),
                                      ),
                                    ),
                                    const DefaultLocationMarker(
                                      child: Icon(
                                        Icons.navigation,
                                        color: Colors.white,
                                      ),
                                    ),
                                  ],
                                ),
                                markerSize: Size(_calculateSize(), _calculateSize()),
                                markerDirection: MarkerDirection.heading,
                              ),
                            ),
                            MarkerLayer(
                              markers: trafficSignMarkers,
                            ),
                          ],
                        ),
                      ),
                      Positioned(
                        bottom: 30,
                        left: 0,
                        right: 0,
                        child: Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              SizedBox(height: 10),
                              isCapturing
                                  ? CircularProgressIndicator()
                                  : ElevatedButton(
                                onPressed: () {
                                  setState(() {
                                    isCapturing = !isCapturing;
                                    if (isCapturing) {
                                      _startImageStream();
                                    } else {
                                      _stopImageStream();
                                    }
                                  });
                                },
                                child: Text(isCapturing
                                    ? 'Stop Capture'
                                    : 'Start Capture'),
                              ),
                            ],
                          ),
                        ),
                      ),
                      Positioned(
                        bottom: 0,
                        left: 10,
                        child: Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Column(
                                children: trafficSignsToShow.map((sign) {
                                  return Image(image: AssetImage("assets/${sign}.png"));
                                }).toList(),
                              ),
                            ],
                          ),
                        ),
                      ),
                      Positioned(
                        bottom: 0,
                        right: 10,
                        child: Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              SizedBox(height: 10),
                              ZoomControls(
                                onZoomIn: _increaseZoom,
                                onZoomOut: _decreaseZoom,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _increaseZoom() {
    setState(() {
      if (_zoomLevel < 18) {
        _zoomLevel = (_zoomLevel + 1).clamp(1.0, 19.0);
        mapController.move(mapController.center, _zoomLevel);
      }
    });
  }

  void _decreaseZoom() {
    setState(() {
      _zoomLevel = (_zoomLevel - 1).clamp(1.0, 19.0);
      mapController.move(mapController.center, _zoomLevel);
    });
  }

  Widget buildSearchBar() {
    TextEditingController searchController = TextEditingController();

    return Container(
      decoration: BoxDecoration(
        boxShadow: [
          BoxShadow(
            color: Colors.grey.withOpacity(0.5),
            spreadRadius: 1,
            blurRadius: 5, // soften the shadow
            offset: Offset(0, 3), // changes position of shadow
          ),
        ],
      ),
      child: TextField(
        controller: searchController,
        decoration: InputDecoration(
          hintText: 'Search Map',
          prefixIcon: Icon(Icons.search),
          suffixIcon: IconButton(
            icon: Icon(Icons.directions),
            onPressed: () async {
              final places = await searchPlaces(searchController.text);
              if (places.isNotEmpty) {
                _onPlaceSelected(places.first);
              }
            },
          ),
          filled: true,
          fillColor: Colors.white,
          contentPadding: EdgeInsets.all(0),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(30),
            borderSide: BorderSide.none,
          ),
        ),
      ),
    );
  }
}

class ZoomControls extends StatelessWidget {
  final VoidCallback onZoomIn;
  final VoidCallback onZoomOut;

  ZoomControls({required this.onZoomIn, required this.onZoomOut});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        IconButton(
          icon: Icon(Icons.add),
          onPressed: onZoomIn,
        ),
        IconButton(
          icon: Icon(Icons.remove),
          onPressed: onZoomOut,
        ),
      ],
    );
  }
}







