/Applications/Godot.app/Contents/MacOS/Godot --headless \
	--export-release "Web" build/web/index.html &&
	python3 -m http.server --directory build/web 8000
