.phony: plan apply

plan:
	clear;
	terraform plan;

apply:
	clear;
	sh build_layer.sh
	terraform apply;