HUGO=hugo
BUILDDIR=target
TARGET_REPO=git@github.com:soider/pages.git

clean:
	@rm -rf ${BUILDDIR}

generate:
	${HUGO}

run:
	hugo server --buildDrafts --watch --port 1313


.PHONY: generate
