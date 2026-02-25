# AGENTS.md - Agentic Coding Guidelines for dart_simple_live

This document provides guidelines for agentic coding agents working on this repository.

## Project Structure

```
dart_simple_live/
├── simple_live_core/      # Core library (Dart package)
├── simple_live_console/   # Console application
├── simple_live_app/       # Main Flutter app
├── simple_live_tv_app/    # Android TV app
└── openspec/              # OpenSpec change definitions
```

## Environment Requirements

- **Flutter SDK**: 3.38
- **Dart SDK**: >=3.0.5 (simple_live_app), >=3.10.0 (simple_live_core, simple_live_console)

## Build, Lint, and Test Commands

### Running the App

```bash
# Run Flutter app
cd simple_live_app && flutter run

# Run TV app
cd simple_live_tv_app && flutter run -d tv

# Run console app
cd simple_live_console && dart run bin/simple_live_console.dart
```

### Linting (Static Analysis)

```bash
# Analyze Flutter app
cd simple_live_app && flutter analyze

# Analyze core library
cd simple_live_core && dart analyze

# Analyze console app
cd simple_live_console && dart analyze
```

### Testing

```bash
# Run all tests in a package
cd simple_live_core && dart test
cd simple_live_console && dart test

# Run all Flutter tests
cd simple_live_app && flutter test

# Run a single test file
cd simple_live_core && dart test test/simple_live_core_test.dart

# Run tests matching a name pattern
cd simple_live_core && dart test --name "bili"

# Run tests in a specific group
cd simple_live_core && dart test --group "bilibili tests"
```

### Code Generation

```bash
# Generate Hive type adapters (simple_live_app)
cd simple_live_app && flutter pub run build_runner build --delete-conflicting-outputs
```

## Code Style Guidelines

### Analysis Configuration

- **simple_live_app**: Uses `package:flutter_lints/flutter.yaml` (Flutter recommended lints)
- **simple_live_core & simple_live_console**: Uses `package:lints/recommended.yaml` (Dart recommended lints)

### Naming Conventions

- **Classes**: `PascalCase` (e.g., `LiveRoom`, `DanmakuParser`)
- **Methods/Variables**: `camelCase` (e.g., `getRoomDetail`, `roomList`)
- **Constants**: `kCamelCase` (e.g., `kDefaultTimeout`)
- **Private members**: `_underscorePrefix` (e.g., `_parseData`)
- **Files**: `snake_case.dart` (e.g., `live_room.dart`)

### Imports

- Use explicit relative imports for local packages
- Group imports in order: dart: > package: > relative
- Use `show`/`hide` to import only what's needed

```dart
// Good
import 'dart:async';
import 'package:dio/dio.dart';
import 'package:simple_live_core/simple_live_core.dart';
import '../models/room.dart';

// Selective import
import 'package:simple_live_core/simple_live_core.dart' show LiveRoom;
```

### Type Annotations

- Always specify return types for functions
- Prefer explicit types over `var` for public APIs
- Use `dynamic` sparingly; prefer `Object?` when appropriate

```dart
// Good
Future<LiveRoom> getRoom(String id) async { ... }
void processItems(List<Item> items) { ... }

// Avoid
var getRoom = (id) async => ...;
```

### Error Handling

- Use try-catch with specific exception types
- Log errors with appropriate levels (logger package is used)
- Return meaningful error results rather than throwing when appropriate

```dart
// Good
try {
  final result = await api.getData();
  return Result.success(result);
} on DioException catch (e) {
  logger.error('Network error', e);
  return Result.failure(e.message);
}
```

### Async/Await

- Always use `async`/`await` over raw Futures for readability
- Handle errors with try-catch in async functions

```dart
// Good
Future<void> loadData() async {
  try {
    final data = await fetchData();
    process(data);
  } catch (e) {
    logger.error('Failed to load', e);
  }
}
```

### Widgets (Flutter)

- Use `const` constructors wherever possible
- Extract widgets for reusable UI components
- Follow Flutter best practices from official documentation

## Architecture Patterns

### Core Library (simple_live_core)

- Implements `LiveSite` abstract class for each platform
- Uses `LiveDanmaku` for danmaku handling
- Uses `LiveRoomItem`, `LiveCategory`, `LiveRoomDetail` for data models

### Flutter App (simple_live_app)

- Uses **GetX** for state management, routing, and dependency injection
- Uses **Dio** for HTTP requests
- Uses **Hive** for local storage

### Key Dependencies

- `dio: ^5.9.0` - HTTP client
- `get: ^4.7.3` - State management/routing
- `hive: 2.2.3` - Local storage
- `logger: ^2.6.2` - Logging

## Important Notes

- This project aggregates live streaming platforms (Huya, Douyu, Bilibili, Douyin)
- All features are based on publicly available information
- No逆向工程 or破解 is involved
- Tests in `simple_live_core` perform actual network requests and may take 30+ seconds per danmaku test
