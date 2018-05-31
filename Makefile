HUGO=hugo
BUILDDIR=target
TARGET_REPO=git@github.com:soider/soider.github.io.git

clean:
	@rm -rf ${BUILDDIR}

generate:
	${HUGO}

run:
	hugo server --buildDrafts --watch --port 1313

push:
	git checkout master
	git push origin master

publish: clean generate push
	cd target && git init &&  git add . && git commit -m "Publication" && git remote add origin "https://soider@github.com/soider/soider.github.io.git" && git push -f origin master


.PHONY: generate
