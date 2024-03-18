docker-build:
	docker build -t lanindex:latest --platform=linux/amd64 --platform=linux/arm64 --platform=linux/arm/v7 .

docker-run:
	docker run --rm -p 8080:80 -v $(PWD)/config.json:/app/config.json lanindex

docker-push:
	docker tag lanindex:latest ncr.lan:80/lanindex:latest
	docker push ncr.lan:80/lanindex:latest
