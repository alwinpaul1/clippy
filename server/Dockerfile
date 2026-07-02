# Build a self-contained AOT executable, then run it on a minimal image.
FROM dart:stable AS build
WORKDIR /app
COPY pubspec.* ./
RUN dart pub get
COPY . .
RUN dart compile exe bin/relay.dart -o bin/server

FROM scratch
COPY --from=build /runtime/ /
COPY --from=build /app/bin/server /app/bin/server
# Railway injects PORT at runtime; the server reads it (defaults to 8080).
EXPOSE 8080
CMD ["/app/bin/server"]
