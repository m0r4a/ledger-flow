check:
	terraform fmt -check ./terraform
	tflint --chdir=./terraform
	golangci-lint run ./go
