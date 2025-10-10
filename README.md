# DeliveryKick Infrastructure Repository

This repository contains all AWS infrastructure configuration and deployment scripts for the DeliveryKick platform.

## Purpose

This infrastructure repository is **separate** from application repositories to provide:

- **Clear Separation of Concerns**: Infrastructure code vs application code
- **Multi-Application Support**: Supports multiple DeliveryKick apps (ordering, restaurant)
- **Environment Management**: Independent dev/staging/prod configurations
- **Security**: Better access control and secrets management
- **Team Collaboration**: Infrastructure team can work independently

## Repository Structure

```
deliverykick-infrastructure/
├── terraform/                      # Infrastructure as Code
│   ├── environments/
│   │   ├── dev/                   # Development environment
│   │   ├── staging/               # Staging environment
│   │   └── prod/                  # Production environment
│   └── modules/
│       ├── aurora/                # Aurora Serverless v2 module
│       ├── ecs/                   # ECS Fargate module
│       ├── networking/            # VPC, subnets, security groups
│       └── secrets/               # Secrets Manager module
├── scripts/
│   ├── deployment/                # Deployment automation scripts
│   │   ├── setup-deliverykick-secure.sh
│   │   ├── migrate-to-aurora.sh
│   │   └── setup-shared-aurora.sh
│   └── utilities/                 # Utility scripts
└── docs/                          # Infrastructure documentation
    ├── AURORA_SETUP_WORKFLOW.md
    ├── POSTGRES_USER_SECURITY.md
    ├── DEPLOYMENT_STRATEGY_RECOMMENDATION.md
    └── ...
```

## What's Managed Here

### AWS Resources
- **Aurora Serverless v2**: PostgreSQL clusters for all applications
- **ECS Fargate**: Container orchestration
- **VPC & Networking**: Subnets, security groups, routing
- **Secrets Manager**: Database credentials and secrets
- **IAM**: Roles and policies
- **CloudWatch**: Monitoring and logging

### Deployment Scripts
- Aurora cluster setup with security model
- Database migration scripts
- User permission management
- Environment configuration generation

### Documentation
- Aurora setup workflows
- Security models and best practices
- Deployment strategies
- Cost optimization guides

## Applications Using This Infrastructure

1. **Ordering Backend** (`Ordering-Delivery-and-Payment-Backend`)
   - Database: `deliverykick_ordering_prod`
   - Users: `dk_ordering_admin`, `dk_ordering_app`, `dk_ordering_readonly`

2. **Restaurant Backend** (separate repo)
   - Database: `deliverykick_restaurant_prod`
   - Users: `dk_restaurant_admin`, `dk_restaurant_app`, `dk_restaurant_readonly`

## Quick Start

> **Amazon Linux / EC2 Users:**
> - **Super Quick:** [QUICKSTART_AMAZON_LINUX.md](QUICKSTART_AMAZON_LINUX.md) (30-45 min total setup)
> - **Detailed:** [docs/SETUP_AMAZON_LINUX.md](docs/SETUP_AMAZON_LINUX.md)
>
> **macOS Users:** Continue with instructions below

### Initial Setup

1. **Create Aurora Cluster** (one-time):
```bash
cd scripts/deployment
./setup-deliverykick-secure.sh
```

This creates:
- Aurora cluster with 2 databases
- 8 users total (4 per database)
- All credentials in AWS Secrets Manager
- Configuration files for each app

### For Application Teams

Configuration files are generated in `aurora-config-secure/` (not committed):

**Ordering App Team:**
- `ordering-admin.env` - For migrations
- `ordering-app.env` - For runtime
- `ordering-readonly.env` - For analytics

**Restaurant App Team:**
- `restaurant-admin.env` - For migrations
- `restaurant-app.env` - For runtime
- `restaurant-readonly.env` - For analytics

## Security Model

### 4 Users Per Database

1. **Master User** (`postgres`)
   - Emergency use only
   - NEVER use in applications

2. **Admin User** (`dk_*_admin`)
   - Run migrations only
   - Can CREATE/ALTER/DROP tables
   - Connection limit: 5

3. **Application User** (`dk_*_app`) ⭐ MAIN USER
   - Django runtime
   - SELECT/INSERT/UPDATE/DELETE only
   - CANNOT drop tables (safe!)
   - Connection limit: 50

4. **Read-Only User** (`dk_*_readonly`)
   - Analytics and BI tools
   - SELECT only
   - Connection limit: 20

See `docs/POSTGRES_USER_SECURITY.md` for details.

## Environment Configuration

### Development
- Lower resource limits
- Publicly accessible (for development)
- Basic monitoring

### Staging
- Production-like configuration
- Limited access
- Full monitoring

### Production
- High availability
- Private subnets
- Comprehensive monitoring
- Automated backups

## Terraform Usage (Future)

```bash
cd terraform/environments/prod

# Initialize
terraform init

# Plan changes
terraform plan

# Apply
terraform apply
```

## Cost Optimization

Current setup costs approximately:
- **Idle**: ~$43/month (0.5 ACU minimum)
- **Low Load**: ~$86/month (1 ACU average)
- **Medium Load**: ~$172/month (2 ACU average)

**50% savings** vs separate clusters per app!

See `docs/ULTRA_LOW_COST_DEPLOYMENT.md` for details.

## Deployment Workflow

### Phase 1: Infrastructure Setup
1. Create Aurora cluster
2. Configure security groups
3. Set up Secrets Manager

### Phase 2: Application Migration
1. Run migrations with admin user
2. Test with app user
3. Deploy to ECS

### Phase 3: Monitoring
1. Set up CloudWatch alarms
2. Configure dashboards
3. Test failover

See `docs/DEPLOYMENT_STRATEGY_RECOMMENDATION.md` for complete workflow.

## Key Documentation

| Document | Purpose |
|----------|---------|
| `SECURE_AURORA_COMPLETE.md` | Complete Aurora setup guide |
| `POSTGRES_USER_SECURITY.md` | Security model and permissions |
| `DEPLOYMENT_STRATEGY_RECOMMENDATION.md` | Phased deployment approach |
| `AURORA_SETUP_WORKFLOW.md` | Step-by-step setup |
| `MULTI_REPO_AURORA_SETUP.md` | Multi-app configuration |

## AWS Regions

- **Primary**: `us-east-1`
- **Backup**: TBD

## Secrets Management

All secrets stored in AWS Secrets Manager:
```
deliverykick/prod/master
deliverykick/prod/ordering/admin
deliverykick/prod/ordering/app
deliverykick/prod/ordering/readonly
deliverykick/prod/restaurant/admin
deliverykick/prod/restaurant/app
deliverykick/prod/restaurant/readonly
```

**Never commit** these to git!

## Support

- **Issues**: Create GitHub issues in this repo
- **Questions**: Check `docs/` directory first
- **Emergencies**: Use master credentials (store safely)

## Contributing

1. Create feature branch
2. Make infrastructure changes
3. Test in dev environment
4. Create PR with detailed description
5. Apply to staging, then prod after approval

## Related Repositories

- **Ordering Backend**: Application code for ordering service
- **Restaurant Backend**: Application code for restaurant service
- **Frontend**: Web application (future)

---

**Version**: 1.0
**Created**: 2025-10-09
**Last Updated**: 2025-10-09
**Maintained By**: Infrastructure Team
