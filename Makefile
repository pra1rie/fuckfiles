OUT = ff

all:
	dub build --build=release

install: all
	install $(OUT) /usr/local/bin
	@mkdir -p ~/.config/ff/scripts
	install scripts/* ~/.config/ff/scripts
