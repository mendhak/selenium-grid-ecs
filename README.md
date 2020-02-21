# Selenium Grid in ECS using Fargate Spot Containers


Replace the variables at the top of main.tf: the VPC ID, private subnets and public subnets.

Then run `terraform apply`

Wait a few minutes, then look at the ECS cluster page in AWS Console.  Ensure everything is running.  You can view browser logs in Cloudwatch. 



## Run a test

Grab the `output` laod balancer DNS address. Then run a test

```bash
npm install smashtest
npx smashtest --test-server=http://your-load-balancer-12345.eu-west-1.elb.amazonaws.com/wd/hub --max-parallel=7

```

## Destroy

Run `terraform destroy` to tear down the infrastructure created here.  

## Details

More info available in the [writeup](https://code.mendhak.com/selenium-grid-ecs/)
