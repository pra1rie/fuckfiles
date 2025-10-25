OUT = ff

all:
	dub build --build=release

install: all
	mkdir -p /usr/local/bin/
	install -s $(OUT) /usr/local/bin/

uninstall:
	rm /usr/local/bin/$(OUT)

.PHONY: all install uninstall
