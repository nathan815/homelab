TAG=latest

.PHONY: docker-build-push docker-run ansible-deploy-playbook deploy

docker-build-push:
	docker buildx build -t ncr.lan:80/lanindex:${TAG} --platform=linux/amd64 --platform=linux/arm64 --platform=linux/arm/v7 --push --output=type=registry,registry.insecure=true .

docker-run:
	docker run --rm -p 8080:80 -v $(PWD)/config.json:/app/config.json lanindex

ansible-deploy-playbook:
	cd ../ansible && ./ansible_playbook.sh playbooks/core-services.yml --tag lanindex --limit pi01

deploy: docker-build-push ansible-deploy-playbook
