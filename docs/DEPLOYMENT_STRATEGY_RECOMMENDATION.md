# DeliveryKick Production Deployment Strategy
## Recommended Approach for Aurora + Both Apps

**Date**: 2025-10-09
**Status**: Recommendation for Review

---

## 🎯 Your Question

> Should we deploy Aurora with both databases and get the ordering database streaming to prod and ordering app deployed to ECS prod?

---

## ✅ Recommended Approach: **Phased Deployment**

Deploy in phases to minimize risk and ensure stability.

---

## 📋 Phase 1: Aurora Cluster Setup (Week 1)

### What to Do
Create the Aurora cluster with **both databases** but don't switch production traffic yet.

### Steps

```bash
# 1. Run the secure setup script
./scripts/deployment/setup-deliverykick-secure.sh

# Creates:
# - Aurora cluster: deliverykick-prod-cluster
# - Database: deliverykick_ordering_prod (for ordering app)
# - Database: deliverykick_restaurant_prod (for restaurant app)
# - 8 users total (4 per database)
# - All credentials in Secrets Manager
```

### What You Get
✅ Aurora cluster running (both databases created)
✅ All users configured with proper permissions
✅ Credentials stored securely
✅ Configuration files for both apps
✅ Cluster is live but **not receiving production traffic yet**

### Time
- Setup: 20-30 minutes
- Cluster creation: 10-15 minutes
- **Total: ~45 minutes**

### Cost
- Starts at **~$43/month** (0.5 ACU minimum)
- Will increase to **~$86-172/month** when both apps are running

### Risk
- **Low** - Cluster is separate from existing production
- No impact to current production

---

## 📋 Phase 2: Ordering App to Production (Week 2)

### What to Do
Migrate **ordering app only** to Aurora and deploy to ECS production.

### Prerequisites
- [ ] Aurora cluster is healthy (Phase 1 complete)
- [ ] ECS cluster exists or create new one
- [ ] Docker image built and tested
- [ ] Environment variables configured
- [ ] Security groups allow ECS → Aurora

### Steps

#### 2.1 Prepare Ordering App

```bash
# Update .env for production
cp aurora-config-secure/ordering-app.env .env.prod

# Test connection locally (if possible)
export $(cat .env.prod | xargs)
python manage.py dbshell

# Run migrations (admin user)
export $(cat aurora-config-secure/ordering-admin.env | xargs)
python manage.py migrate
```

#### 2.2 Build and Push Docker Image

```bash
# Build image
docker build -t deliverykick-ordering:prod -f Dockerfile.prod .

# Tag for ECR
docker tag deliverykick-ordering:prod \
    <account-id>.dkr.ecr.us-east-1.amazonaws.com/deliverykick-ordering:prod

# Push to ECR
docker push <account-id>.dkr.ecr.us-east-1.amazonaws.com/deliverykick-ordering:prod
```

#### 2.3 Deploy to ECS

**Option A: New ECS Cluster** (Recommended)
```bash
# Create ECS cluster
aws ecs create-cluster --cluster-name deliverykick-prod

# Create task definition (see template below)
aws ecs register-task-definition --cli-input-json file://task-definition.json

# Create service
aws ecs create-service \
    --cluster deliverykick-prod \
    --service-name ordering-service \
    --task-definition ordering-app:1 \
    --desired-count 2 \
    --launch-type FARGATE
```

**Option B: Existing ECS Cluster**
```bash
# Update existing task definition
# Deploy new revision
aws ecs update-service \
    --cluster existing-cluster \
    --service ordering-service \
    --task-definition ordering-app:new-revision \
    --force-new-deployment
```

#### 2.4 ECS Task Definition Template

```json
{
  "family": "ordering-app",
  "networkMode": "awsvpc",
  "requiresCompatibilities": ["FARGATE"],
  "cpu": "512",
  "memory": "1024",
  "containerDefinitions": [
    {
      "name": "ordering-app",
      "image": "<account-id>.dkr.ecr.us-east-1.amazonaws.com/deliverykick-ordering:prod",
      "portMappings": [
        {
          "containerPort": 8000,
          "protocol": "tcp"
        }
      ],
      "environment": [
        {
          "name": "DB_HOST_SERVER",
          "value": "<aurora-endpoint>"
        },
        {
          "name": "DB_NAME",
          "value": "deliverykick_ordering_prod"
        },
        {
          "name": "DB_PORT",
          "value": "5432"
        },
        {
          "name": "DB_USER",
          "value": "dk_ordering_app"
        }
      ],
      "secrets": [
        {
          "name": "DB_PASSWORD",
          "valueFrom": "deliverykick/prod/ordering/app:password::"
        }
      ],
      "logConfiguration": {
        "logDriver": "awslogs",
        "options": {
          "awslogs-group": "/ecs/ordering-app",
          "awslogs-region": "us-east-1",
          "awslogs-stream-prefix": "ecs"
        }
      }
    }
  ]
}
```

#### 2.5 Verify Deployment

```bash
# Check ECS service status
aws ecs describe-services \
    --cluster deliverykick-prod \
    --services ordering-service

# Check task health
aws ecs list-tasks --cluster deliverykick-prod --service-name ordering-service

# Check application logs
aws logs tail /ecs/ordering-app --follow

# Test endpoint
curl https://your-alb-endpoint.com/health/
```

### What You Get
✅ Ordering app running on ECS in production
✅ Streaming data to Aurora (deliverykick_ordering_prod)
✅ Using secure app user (cannot drop tables)
✅ Scalable ECS deployment
✅ CloudWatch logging

### Time
- Preparation: 2-3 hours
- Deployment: 1-2 hours
- Testing: 1-2 hours
- **Total: 4-7 hours**

### Risk
- **Medium** - Production traffic affected
- Mitigation: Blue/green deployment, rollback plan

---

## 📋 Phase 3: Restaurant App to Production (Week 3-4)

### What to Do
Deploy restaurant app to Aurora and ECS production.

### Prerequisites
- [ ] Phase 2 complete and stable
- [ ] Restaurant team has received config files
- [ ] Restaurant app configured for production
- [ ] Restaurant app tested with Aurora

### Steps

#### 3.1 Share with Restaurant Team

```bash
# Send these files to restaurant team
aurora-config-secure/restaurant-admin.env
aurora-config-secure/restaurant-app.env
aurora-config-secure/restaurant-readonly.env
RESTAURANT_APP_SETUP_GUIDE.md
```

#### 3.2 Restaurant Team Actions

Restaurant team follows `RESTAURANT_APP_SETUP_GUIDE.md`:
1. Configure Django settings
2. Run migrations with admin user
3. Test with app user
4. Build Docker image
5. Deploy to ECS

#### 3.3 Monitor Both Apps

```sql
-- Monitor connections from both apps
SELECT
    datname,
    usename,
    COUNT(*) as connections
FROM pg_stat_activity
WHERE datname LIKE 'deliverykick%'
GROUP BY datname, usename;

-- Expected:
-- deliverykick_ordering_prod    | dk_ordering_app     | 45
-- deliverykick_restaurant_prod  | dk_restaurant_app   | 40
```

### What You Get
✅ Both apps running on ECS in production
✅ Both streaming to shared Aurora cluster
✅ **50% cost savings** vs separate clusters
✅ Centralized monitoring
✅ Unified backup strategy

### Time
- Restaurant team preparation: 4-8 hours
- Deployment: 2-4 hours
- **Total: 6-12 hours**

### Risk
- **Low-Medium** - Ordering app already proven stable
- Shared cluster load increases

---

## 🔄 Alternative Approach: Big Bang Deployment

### What It Is
Deploy everything at once (Aurora + both apps to ECS).

### Pros
- Faster to complete
- Single migration window

### Cons
- ❌ Higher risk
- ❌ Harder to troubleshoot
- ❌ Both teams must be ready simultaneously
- ❌ Larger blast radius if issues occur

### Recommendation
**Not recommended** unless you have:
- Very low traffic
- Good rollback plan
- Both teams fully prepared
- Extended maintenance window

---

## 📊 Comparison: Phased vs Big Bang

| Factor | Phased (Recommended) | Big Bang |
|--------|---------------------|----------|
| **Risk** | Low-Medium | High |
| **Rollback** | Easy (one app at a time) | Complex |
| **Timeline** | 3-4 weeks | 1-2 weeks |
| **Team Coordination** | Less critical | Critical |
| **Troubleshooting** | Easier (isolate issues) | Harder |
| **Production Impact** | Minimal (one app) | Higher (both apps) |
| **Recommended** | ✅ Yes | ❌ No |

---

## 🗓️ Recommended Timeline

### Week 1: Aurora Setup
- **Monday**: Run setup script, create Aurora cluster
- **Tuesday**: Verify cluster health, test connections
- **Wednesday**: Configure monitoring, CloudWatch alarms
- **Thursday**: Document endpoint, share with restaurant team
- **Friday**: Buffer day, final checks

### Week 2: Ordering App Deployment
- **Monday**: Prepare ordering app, run migrations
- **Tuesday**: Build Docker image, test locally
- **Wednesday**: Deploy to ECS staging (if available)
- **Thursday**: Deploy to ECS production
- **Friday**: Monitor, optimize, verify

### Week 3-4: Restaurant App Deployment
- **Week 3**: Restaurant team prepares (parallel work)
- **Monday Week 4**: Restaurant team deploys to staging
- **Wednesday Week 4**: Restaurant team deploys to production
- **Friday Week 4**: Final verification, both apps stable

---

## ✅ Recommended Approach Summary

### Yes, Deploy Aurora with Both Databases Now
✅ Create Aurora cluster with both databases (Phase 1)
✅ Configures everything upfront
✅ Both databases ready when needed
✅ Low risk (not connected to production yet)

### Yes, Deploy Ordering App to ECS Prod (Phase 2)
✅ Get ordering app streaming to Aurora
✅ Validate Aurora performance with real traffic
✅ Prove the architecture works
✅ Restaurant app learns from your experience

### Wait for Restaurant App (Phase 3)
⏳ Let restaurant team prepare properly
⏳ They learn from ordering app deployment
⏳ Lower risk with proven cluster
⏳ Can deploy when they're ready

---

## 🚨 Critical Pre-Deployment Checklist

### Aurora Cluster
- [ ] Cluster created and healthy
- [ ] Both databases created
- [ ] All 8 users created with correct permissions
- [ ] Credentials stored in Secrets Manager
- [ ] Security groups configured
- [ ] Backup retention set (7 days)
- [ ] CloudWatch monitoring enabled
- [ ] Connection limits verified

### Ordering App
- [ ] Django settings configured for production
- [ ] Migrations tested with admin user
- [ ] App tested with app user locally
- [ ] Cannot drop tables verified (security test)
- [ ] Docker image built and tested
- [ ] Environment variables documented
- [ ] ECS task definition created
- [ ] ALB/target group configured (if needed)
- [ ] Health check endpoint working
- [ ] Rollback plan documented

### Restaurant App
- [ ] Setup guide shared with team
- [ ] Config files shared
- [ ] Team acknowledges receipt
- [ ] Team has timeline for their deployment

---

## 📈 Expected Performance

### Aurora Cluster
- **ACUs**: Start at 0.5, scale to 1-2 under load
- **Connections**: 50 per app = 100 total (well under limits)
- **Latency**: <10ms from ECS (same region)
- **Cost**: $86-172/month for both apps

### ECS Deployment
- **Ordering App**: 2-4 tasks recommended
- **Restaurant App**: 2-4 tasks recommended
- **CPU**: 512 or 1024 per task
- **Memory**: 1024-2048 MB per task

---

## 🔙 Rollback Plan

### If Ordering App Has Issues on ECS

**Option 1: Rollback ECS deployment**
```bash
# Revert to previous task definition
aws ecs update-service \
    --cluster deliverykick-prod \
    --service ordering-service \
    --task-definition ordering-app:previous-revision
```

**Option 2: Switch database back**
```bash
# Update environment to point to old database
# Redeploy with old DB_HOST_SERVER
```

### If Aurora Has Issues

**Backup plan**:
- Aurora has 7-day automated backups
- Can restore to any point in time
- Keep old database until confirmed stable

---

## 💰 Cost Breakdown

### Current State (Before)
- Existing databases: $X/month
- No ECS costs yet (or existing ECS)

### After Phase 1 (Aurora Only)
- Aurora cluster: ~$43/month (idle, 0.5 ACU)
- Total increase: ~$43/month

### After Phase 2 (Ordering on Aurora + ECS)
- Aurora: ~$86-120/month (with load, 1-1.5 ACU)
- ECS Fargate: ~$30-50/month (2 tasks)
- Total increase: ~$116-170/month

### After Phase 3 (Both Apps)
- Aurora: ~$120-172/month (full load, 1.5-2 ACU)
- ECS Fargate: ~$60-100/month (4 tasks total)
- Total increase: ~$180-272/month

**Savings vs two separate clusters**: ~$86/month (50%)

---

## 🎯 Final Recommendation

### ✅ YES - Deploy Aurora with Both Databases Now (Phase 1)

**Reasons**:
- Low risk (not connected to production)
- Both databases ready when needed
- Restaurant team can start preparing
- Proves the infrastructure works
- Low initial cost (~$43/month)

### ✅ YES - Deploy Ordering App to Aurora + ECS Prod (Phase 2)

**Reasons**:
- Validates Aurora performance
- Proves the security model works
- Restaurant team learns from your experience
- Phased approach reduces risk
- Can monitor and optimize before restaurant app

### ⏳ WAIT - Restaurant App Deploys After (Phase 3)

**Reasons**:
- Let them prepare properly
- Learn from ordering app deployment
- Lower risk with proven cluster
- They work in parallel during Week 2-3
- Deploy when ready (not rushed)

---

## 📞 Next Steps

1. **Review this plan** with your team
2. **Schedule Phase 1** (Aurora setup) - Low risk, do soon
3. **Plan Phase 2** (Ordering app) - Medium risk, needs preparation
4. **Coordinate with Restaurant team** - Share timeline and docs
5. **Set up monitoring** - CloudWatch, alarms, dashboards
6. **Document everything** - Runbooks, troubleshooting guides

---

## 📚 Related Documents

- `SECURE_AURORA_COMPLETE.md` - Complete Aurora setup guide
- `DELIVERYKICK_SECURE_SETUP.md` - Setup instructions
- `RESTAURANT_APP_SETUP_GUIDE.md` - For restaurant team
- `docs/POSTGRES_USER_SECURITY.md` - Security model details

---

**Questions?** Let's discuss before proceeding!

**Ready to start Phase 1?** Run the setup script! 🚀
