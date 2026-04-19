/Applications/Godot.app/Contents/MacOS/Godot --headless \
	--export-release "Web" build/web/index.html &&
	python3 tools/serve_web.py 8000
