import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:test_app/camera/PhotoScreen.dart';

List<CameraDescription> cameras = [];

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize cameras globally
  try {
    cameras = await availableCameras();
  } on CameraException catch (e) {
    print('Error initializing cameras: $e');
  }

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    // If there are no cameras, show an error message
    if (cameras.isEmpty) {
      return const MaterialApp(
        home: Scaffold(
          body: Center(
            child: Text("No cameras available"),
          ),
        ),
      );
    }

    // Otherwise, show the PhotoScreen
    return MaterialApp(
      title: 'Camera Demo',
      theme: ThemeData(
        primarySwatch: Colors.blue,
      ),
      home: PhotoScreen(cameras)
    );
  }
}

