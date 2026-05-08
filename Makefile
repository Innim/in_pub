dev-web:
	cd unpub_web &&\
	fvm dart pub global activate webdev &&\
	fvm dart pub global activate webdev_proxy 0.1.1 &&\
	fvm dart pub global run webdev_proxy serve -- --auto=refresh --log-requests

dev-api:
	cd unpub && fvm dart run build_runner watch

build:
	cd unpub_web &&\
	fvm dart run build_runner build --release --delete-conflicting-outputs --output=web:build
	fvm dart unpub/tool/pre_publish.dart
	fvm dart format **/*.dart
