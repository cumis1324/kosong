# Use official Dart image from Docker Hub
FROM dart:stable AS build
FROM ghcr.io/cirruslabs/flutter:3.22.2

# Set working directory inside the container
WORKDIR /app

# Copy pubspec.yaml and pubspec.lock to cache dependencies
COPY pubspec.* ./

# Get dependencies (you may need to add more dependencies if required)
RUN flutter pub get

# Copy the entire project directory to the container
COPY . .

# Compile Dart ahead-of-time (AOT) to improve startup time
RUN dart compile exe bin/main.dart -o main

# Command to run the compiled Dart application
CMD ["./main"]
