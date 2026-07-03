# Railway uploads and builds from the repo root. This Dockerfile builds the
# Dart relay that lives in server/ (its own server/Dockerfile is kept for
# building from inside server/). Build context = repo root.
FROM dart:stable AS build
WORKDIR /app
COPY server/pubspec.* ./
RUN dart pub get
COPY server/ .
RUN dart compile exe bin/relay.dart -o bin/server

FROM scratch
COPY --from=build /runtime/ /
COPY --from=build /app/bin/server /app/bin/server
# Railway injects PORT at runtime; the server reads it (defaults to 8080).
EXPOSE 8080
CMD ["/app/bin/server"]
