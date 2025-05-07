## CREATE FABRIC-NETWORKING RESOURCES
'''
az deployment group create -c -g <RG name> -c --template-file fabric_networking.jsonc --parameters fabric_networking.parameters.jsonc
  az networkfabric l3domain update-admin-state --resource-name "XX-ISDL3" -g "<RG name>" --state Enable	
'''

## CREATE NC-NETWORKING RESOURCES
'''
az deployment group create -c -g <RG name> -c --template-file nc_networking.jsonc --parameters nc_networking.parameters.jsonc				
'''
## CREATE VM
'''
az deployment group create -c -g <RG name> -c --template-file vm.jsonc --parameters vm.parameters.jsonc				
    az ssh arc --local-user azureuser --resource-group <RG name> --name alrs-vm --private-key-file .ssh/id_rsa				
'''
## CREATE A NEW SSHKEY
'''
ssh-keygen -t rsa -b 4096 -f ~/.ssh/my_vm_key
'''