OUT = ff

all:
	dub build --build=release

install: all
	install $(OUT) /usr/local/bin

