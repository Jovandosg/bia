#!/bin/bash
set -e

# =============================================================================
# deploy-versioned.sh
# Deploy versionado por commit hash no ECS
#
# Uso:
#   ./deploy-versioned.sh
#   ./deploy-versioned.sh --cluster cluster-bia-alb --service service-bia-alb
#
# O que este script faz:
#   1. Captura o commit hash do git (7 chars)
#   2. Autentica no ECR
#   3. Builda a imagem Docker
#   4. Taga como <commit-hash> e como latest, faz push das duas
#   5. Cria uma nova revisão da task definition com a imagem versionada
#   6. Atualiza o service ECS com a nova task definition
#   7. Aguarda o deploy estabilizar
# =============================================================================

# --- Configurações fixas do projeto ---
REGION="us-east-1"
ECR_REGISTRY="975050217683.dkr.ecr.us-east-1.amazonaws.com"
ECR_REPO="bia"
TASK_DEF_FAMILY="task-def-bia"
CLUSTER="cluster-bia"
SERVICE="service-bia"

# --- Leitura de parâmetros opcionais ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --cluster)  CLUSTER="$2";  shift 2 ;;
    --service)  SERVICE="$2";  shift 2 ;;
    *)
      echo "Parâmetro desconhecido: $1"
      echo "Uso: $0 [--cluster NOME] [--service NOME]"
      exit 1
      ;;
  esac
done

# --- Captura do commit hash ---
COMMIT_HASH=$(git rev-parse --short HEAD 2>/dev/null || echo "")
if [ -z "$COMMIT_HASH" ]; then
  echo "ERRO: Não foi possível obter o commit hash. Este diretório é um repositório git?"
  exit 1
fi

IMAGE_URI="$ECR_REGISTRY/$ECR_REPO"
IMAGE_VERSIONED="$IMAGE_URI:$COMMIT_HASH"
IMAGE_LATEST="$IMAGE_URI:latest"

echo "============================================="
echo " Deploy Versionado - BIA"
echo "============================================="
echo " Commit hash  : $COMMIT_HASH"
echo " Cluster      : $CLUSTER"
echo " Service      : $SERVICE"
echo " Task Family  : $TASK_DEF_FAMILY"
echo " Imagem       : $IMAGE_VERSIONED"
echo "============================================="
echo ""

# --- 1. Autenticação no ECR ---
echo "[1/6] Autenticando no ECR..."
aws ecr get-login-password --region "$REGION" \
  | docker login --username AWS --password-stdin "$ECR_REGISTRY"

# --- 2. Build da imagem ---
echo ""
echo "[2/6] Buildando a imagem Docker..."
docker build -t "$ECR_REPO" .

# --- 3. Tag e push ---
echo ""
echo "[3/6] Tagging e push para o ECR..."
docker tag "$ECR_REPO:latest" "$IMAGE_VERSIONED"
docker tag "$ECR_REPO:latest" "$IMAGE_LATEST"

docker push "$IMAGE_VERSIONED"
docker push "$IMAGE_LATEST"

echo " ✔ Tag $COMMIT_HASH publicada no ECR"
echo " ✔ Tag latest atualizada no ECR"

# --- 4. Busca a task definition atual ---
echo ""
echo "[4/6] Buscando task definition atual ($TASK_DEF_FAMILY)..."
CURRENT_TASK_DEF=$(aws ecs describe-task-definition \
  --region "$REGION" \
  --task-definition "$TASK_DEF_FAMILY" \
  --query "taskDefinition" \
  --output json)

# --- 5. Registra nova revisão da task definition ---
echo ""
echo "[5/6] Registrando nova revisão da task definition com imagem $COMMIT_HASH..."

# Monta o JSON trocando apenas a imagem de todos os containers
# Remove campos que a API não aceita no register-task-definition
NEW_TASK_DEF=$(echo "$CURRENT_TASK_DEF" | jq \
  --arg IMAGE "$IMAGE_VERSIONED" \
  'del(.taskDefinitionArn, .revision, .status, .requiresAttributes, .compatibilities, .registeredAt, .registeredBy, .deregisteredAt)
  | .containerDefinitions[0].image = $IMAGE')

NEW_TASK_DEF_ARN=$(aws ecs register-task-definition \
  --region "$REGION" \
  --cli-input-json "$NEW_TASK_DEF" \
  --query "taskDefinition.taskDefinitionArn" \
  --output text)

# Extrai só a parte legível: task-def-bia:29
NEW_TASK_DEF_SHORT=$(echo "$NEW_TASK_DEF_ARN" | awk -F'/' '{print $NF}')

echo " ✔ Nova task definition: $NEW_TASK_DEF_SHORT"
echo "   ARN: $NEW_TASK_DEF_ARN"

# --- 6. Atualiza o service ---
echo ""
echo "[6/6] Atualizando service $SERVICE no cluster $CLUSTER..."
aws ecs update-service \
  --region "$REGION" \
  --cluster "$CLUSTER" \
  --service "$SERVICE" \
  --task-definition "$NEW_TASK_DEF_ARN" \
  --output text \
  --query "service.taskDefinition" > /dev/null

echo " ✔ Service atualizado para $NEW_TASK_DEF_SHORT"

# --- 7. Aguarda estabilização ---
echo ""
echo "Aguardando o deploy estabilizar (pode levar alguns minutos)..."
aws ecs wait services-stable \
  --region "$REGION" \
  --cluster "$CLUSTER" \
  --services "$SERVICE"

echo ""
echo "============================================="
echo " Deploy concluído com sucesso!"
echo "---------------------------------------------"
echo " Cluster         : $CLUSTER"
echo " Service         : $SERVICE"
echo " Imagem (ECR)    : $IMAGE_VERSIONED"
echo " Task Definition : $NEW_TASK_DEF_SHORT"
echo "============================================="
echo ""
echo " Rollback para versão anterior:"
echo " aws ecs update-service --cluster $CLUSTER --service $SERVICE \\"
echo "   --task-definition $TASK_DEF_FAMILY:<REVISAO_ANTERIOR>"
echo "============================================="
