Script Instructions


Prerequisites: 
1) GPU Drivers / Fabric Manager

2) Install ipmitool (If Missing): 

> sudo apt update
> sudo apt install ipmitool

3) Install DCGM tool (If Missing): 

> sudo apt update
> sudo apt install datacenter-gpu-manager
 

Running Script: 

1) Make Script Executable:
> chmod +x master_thermal_test.sh

2) Run Script: 
> ./master_thermal_test.sh

Script Notes / Details: 
Once script is ran, it will ask to input the GPU Generation used for Thermal Testing. 
Once selected the appropriate GPU Thermal Test will run and generate a Thermal CSV Log. 
Once completed, please provide the Thermal CSV Log to appropriate TS Engineer to review. 