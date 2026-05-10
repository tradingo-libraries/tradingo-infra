ANSIBLE = ansible-playbook -u admin
INVENTORY = inventory/hosts.yml

.PHONY: deploy deploy-monitoring sync-platform deploy-crons cluster-status bootstrap

deploy:
	$(ANSIBLE) playbooks/deploy-stack.yml -e image_tag=$(tag)

deploy-monitoring:
	$(ANSIBLE) playbooks/deploy-monitoring.yml

sync-platform:
	$(ANSIBLE) playbooks/sync-platform.yml

deploy-crons:
	$(ANSIBLE) playbooks/deploy-crons.yml

cluster-status:
	$(ANSIBLE) playbooks/cluster-status.yml

bootstrap:
	$(ANSIBLE) playbooks/bootstrap-nodes.yml