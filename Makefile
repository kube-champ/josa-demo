seal-file:
	@[ "${file}" ] || ( echo "*** file is not set"; exit 1 )
	@[ "${name}" ] || ( echo "*** name is not set"; exit 1 )
	@[ "${ns}" ] || ( echo "*** ns is not set"; exit 1 )

	mkdir -p .secrets/generated

	kubectl create secret generic $(name) -n $(ns) \
	--from-file=$(file) \
	--dry-run=client \
	-o json > .secrets/generated/$(name).json

	kubeseal --format=yaml --cert=.secrets/cert.pem \
		--scope=strict \
		--namespace=$(ns) < .secrets/generated/$(name).json > .secrets/generated/$(name).yaml

	rm .secrets/generated/$(name).json

external-dns:
	make seal-file name=external-dns-credentials ns=external-dns file=.secrets/external-dns-credentials.yaml

flux-alerts-slack:
	kubectl -n flux-system create secret generic flux-slack-url \
		--from-literal=address=${JOSA_SLACK_URL} \
		--dry-run=client \
		-o json > .secrets/flux-slack-url.json

	kubeseal --format=yaml --cert=.secrets/cert.pem \
		--scope=strict \
		--namespace=flux-system < .secrets/flux-slack-url.json > .secrets/generated/flux-slack-url.yaml

up:
	cd terraform/infra; terraform init
	cd terraform/infra; terraform apply -auto-approve
	cd terraform/infra; terraform output -raw kubeconfig > ../../kubeconfig_josa
	
	sleep 5s;

	cd terraform/flux-bootstrap; terraform init
	cd terraform/flux-bootstrap; terraform apply -auto-approve
	cd terraform/flux-bootstrap; terraform output -raw sealed_secrets_generated_cert > ../../.secrets/cert.pem

	cd terraform/flux-bootstrap; terraform output -raw flux_generated_public_key > ../../git_ssh.pub

	echo ">> moving sealed secrets cert into .secrets/cert.pem"
	cd terraform/flux-bootstrap; terraform output sealed_secrets_generated_cert > ../../.secrets/cert.pem
	
	echo ">> generating sealed secrets - external dn"
	make external-dns

	mv .secrets/generated/external-dns-credentials.yaml flux/infrastructure/josa/tooling/external-dns/external-dns-credentials.yaml

	echo ">> generating sealed secrets - flux slack"
	make flux-alerts-slack
	
	mv .secrets/generated/flux-slack-url.yaml flux/alerts/josa/alerts/secret.yaml

	git add .
	git commit -m "new infrastructure and sealed secrets created"
	git push origin main

down:
	cd terraform/flux-bootstrap; terraform init
	cd terraform/flux-bootstrap; terraform destroy -auto-approve
	sleep 5s;
	cd terraform/infra; terraform init
	cd terraform/infra; terraform destroy -auto-approve

flux-restart:
	kubectl rollout restart deploy/notification-controller -n flux-system
	kubectl rollout restart deploy/helm-controller -n flux-system
	kubectl rollout restart deploy/kustomize-controller -n flux-system
	kubectl rollout restart deploy/source-controller -n flux-system

watch-hello:
	@while sleep 5; do curl --insecure -s https://hello.josa.kubechamp.gq/ | grep -A 2 "message" | sed -n 2p; done