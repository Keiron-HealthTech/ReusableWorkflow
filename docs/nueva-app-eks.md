# Llevar una app nueva a Kubernetes (EKS) con ReusableWorkflow

Guía para los equipos de producto que tienen una app (API, worker, servicio) en su propio
repo y quieren desplegarla en los clusters de Keiron: **staging** (QA) y **producción**.

Si trabajas con un agente de IA (Claude Code, Codex, etc.), instala la skill de la
sección 8: aplica esta guía sobre tu repo y te deja lista la solicitud para tech-ops.

## 1. Cómo se reparte el trabajo

Tu repo **solo construye la imagen y la publica**. Todo lo que corre en el cluster lo
levanta y lo mantiene tech-ops.

| Tu equipo (repo de la app) | tech-ops (infra) |
|---|---|
| Dockerfile que compila para `arm64` | Repositorio ECR por ambiente |
| Endpoint de health y puerto configurable | Namespace, Deployment, Service, Ingress y autoescalado |
| Workflows de deploy en `.github/workflows/` (sección 4) | Permiso OIDC del repo y de sus ramas |
| Lista de variables de entorno y sus valores (sección 5) | Configs de Doppler, carga de valores y sincronización al cluster |
| Solicitud con los datos de la sección 3 | Alta de la app y verificación del primer deploy |

En el repo de la app **no** van manifiestos de Kubernetes, charts de Helm, Terraform/CDK ni
credenciales de AWS. Réplicas, CPU/memoria, rutas públicas o permisos AWS se piden a tech-ops;
viven en los repos de infra.

## 2. Flujo completo

1. Preparas la app con el checklist de la sección 3.
2. Pides el alta por **Solicitudes de Accesos**: `/asks` en Slack, formulario "Solicitud de
   Acceso" (sección 3).
3. tech-ops crea el ECR, habilita tu repo por OIDC, crea las configs de Doppler y levanta el
   Deployment con una imagen de relleno. Te responde en la misma solicitud con `app_name`,
   `namespace`, los nombres de ECR y la URL de la app.
4. Agregas los workflows (sección 4) y coordinas con tech-ops los valores de las variables
   (sección 5).
5. Merge a `development` → se construye la imagen y se despliega en **staging**. Validas.
6. Merge a `main` → se despliega en **producción**.

**Producción es el ambiente estable.** Staging no tiene garantías de disponibilidad de parte de
infra: puede caerse, reiniciarse o cambiar sin aviso. Además, una app en staging **nunca debe
conectarse a nada de producción** (bases de datos, colas, buckets, APIs). Si tu app no tiene
recursos de staging a los que conectarse, no va a staging: se despliega solo en producción, te
saltas el paso 5 y creas solo el workflow de producción.

Hasta el primer deploy desde tu CI, el pod corre una imagen de relleno que se cae sola
(aparece como `CrashLoopBackOff`). Es esperado: el primer merge lo reemplaza.

## 3. Antes de pedir el alta

### Checklist de la app

- [ ] **La imagen corre en `arm64`.** Ambos clusters son ARM (AWS Graviton). Usa imágenes base
      multi-arquitectura (`node:22-slim`, `python:3.12-slim`, etc.) y compila las dependencias
      nativas dentro del build. Una imagen solo `amd64` se cae con `exec format error` y sin
      logs. Pruébalo: `docker buildx build --platform linux/arm64 .`
- [ ] **Dockerfile limpio:** multi-stage, `.dockerignore` (`node_modules`, `.git`, `.env*`),
      sin secretos ni `.env` dentro de la imagen, usuario no root.
- [ ] **Una imagen para todos los ambientes.** Toda diferencia entre staging y prod llega por
      variables de entorno; nada de archivos de config por ambiente horneados en la imagen.
- [ ] **Escucha en `0.0.0.0` y en el puerto de la variable `PORT`** (por defecto `5000`; el
      valor se acuerda con tech-ops).
- [ ] **Rutas según cómo se publique la app.** tech-ops evalúa la forma y te la confirma en la
      respuesta a la solicitud:
      - **Prefijo** en el dominio compartido, por ejemplo `https://api.keiron.cl/revenue/algo`.
        El balanceador no reescribe el path, así que la app tiene que responder en
        `/<prefijo>/...` (prefijo global del router de tu framework, por ejemplo
        `app.setGlobalPrefix('<prefijo>')` en NestJS).
      - **Subdominio propio**, si tech-ops evalúa que es lo mejor, por ejemplo
        `https://revenue.api.keiron.cl/algo`. Ahí la app responde desde la raíz.

      Si aún no lo sabes, deja el prefijo configurable por variable de entorno.
- [ ] **Healthcheck:** `GET <ruta base>/healthz` (por ejemplo `/<prefijo>/healthz`) responde
      `200` en menos de un segundo, sin depender de servicios externos lentos. Kubernetes no manda tráfico al pod hasta que
      responde, y lo saca si deja de responder.
- [ ] **Apagado limpio:** maneja `SIGTERM`, termina los requests en curso y cierra conexiones en
      menos de 30 segundos. Arranca con forma exec (`CMD ["node", "dist/main.js"]`), no con
      `npm start` ni un `sh -c`, para que la señal llegue al proceso.
- [ ] **Sin estado local:** nada en disco que deba sobrevivir. Puede haber varias réplicas y
      cualquier pod se reemplaza en cualquier momento.
- [ ] **Logs a stdout/stderr**, ojalá en JSON. No escribas archivos de log; se recolectan solos
      en New Relic.
- [ ] **Sin credenciales AWS en el código ni en variables.** Si la app necesita S3, SQS, Bedrock
      u otro servicio, pídelo en la solicitud: el pod recibe permisos por identidad, sin llaves.

### Si tu app necesita login o permisos

Si los usuarios tienen que iniciar sesión, o tu API tiene que saber quién la llama y qué puede
hacer, usa la auth central de Keirón: no crees usuarios, contraseñas ni roles propios. Sigue
[`auth-apps.md`](auth-apps.md) (o su skill `keiron-auth`) y pídelo en una solicitud aparte; los
equipos no tienen acceso al repo de auth, todo se gestiona con tech-ops.

### Qué nos tienes que pasar

Todo llega a tech-ops por **Solicitudes de Accesos**: escribe `/asks` en Slack y elige el
formulario "Solicitud de Acceso" (queda como issue en el equipo SOL de Linear, con aprobación
de tu líder según el procedimiento de gestión de accesos). Sin solicitud aprobada no se levanta
nada.

Lo principal es **el alta de la app** (una solicitud por app): que tu repo pueda desplegar en
EKS. Los accesos de personas son aparte y solo si de verdad se necesitan (solicitud 2).

#### Solicitud 1: alta de la app

Campos del formulario:

| Campo | Qué poner |
|---|---|
| Título | `<Nombre Apellido del responsable> - EKS <app>` |
| Email corporativo | El del responsable técnico de la app |
| Área / Rol | Equipo y rol del responsable (ej. `Desarrollo CRM`) |
| Líder / Gerente que aprueba | Líder del equipo dueño de la app |
| Tipo | `Alta` |
| Fecha requerida | Cuándo necesitas el primer ambiente listo (cuenta unos días hábiles) |
| Vigencia | `Permanente` |
| Sistema | `AWS` |
| Subsistema, módulo o recurso | `EKS: despliegue de <app> desde Keiron-HealthTech/<repo> (staging y prod, o solo prod)` |
| Nivel de acceso | `Otro` |
| Permisos específicos | `Deploy por GitHub Actions (OIDC) desde las ramas <development> y <main>; repositorios ECR de la app; configs de Doppler staging_<app> y production_<app>` |
| Justificación | Para qué sirve la app y la ficha técnica de abajo, completa |

Ficha técnica para pegar en **Justificación** (los nombres de variables van sin valores):

```markdown
Qué hace la app: <una o dos frases>

- Repo: Keiron-HealthTech/<repo>
- Nombre de la app (kebab-case): <app>
- Equipo / namespace sugerido: <crm | platform | ai | ...>
- Ambientes: staging y prod | solo prod
- Recursos de staging a los que se conecta (sin nada de prod): <cuáles>
- Ramas: staging = development, prod = main (indicar si son otras)
- Dockerfile: <ruta>  (monorepo: una entrada por app)
- Puerto (PORT): 5000
- Healthcheck: GET <ruta base>/healthz
- Login o permisos: no | sí (solicitud de auth aparte)
- Exposición: pública | interna | sin HTTP (worker). La URL final la define tech-ops.
- Recursos estimados por réplica: CPU <x>, memoria <y>; réplicas mín/máx <a>/<b>
- Variables de entorno (solo nombres): DATABASE_URL, ...
- Recursos externos: bases de datos, colas, buckets, APIs, IPs fijas de salida
- Permisos AWS que necesita el pod: <ninguno | S3 bucket X lectura | ...>
- Tareas programadas o migraciones dentro de la app: <sí/no y cómo>
- Conexiones largas (websockets, SSE, requests > 60 s): <sí/no>
- ¿Procesa datos personales o de salud?: <sí/no, cuáles>
- Checklist de la sección 3: <cumple todo | pendientes: ...>
```

#### Solicitud 2: accesos de personas (solo si se necesitan)

Los accesos no vienen incluidos con el alta: se dan solo cuando hacen falta para el trabajo de
la persona y quedan sujetos a evaluación de tech-ops. Si alguien del equipo necesita ver los logs
y métricas de la app, pídelo con el mismo formulario, una solicitud por persona, explicando para
qué lo necesita:

| Sistema | Subsistema / recurso | Nivel | Permisos específicos |
|---|---|---|---|
| `New Relic` | `Logs y APM de <app>` | `ReadOnly` | `Ver logs y métricas de <app>` |

Doppler no se pide: por ahora los valores los administra tech-ops (sección 5).

## 4. Workflows en tu repo

Un archivo por ambiente; si tu app va solo a producción, crea solo el de prod. Cada uno llama a
[`buildAndDeployKubernetes.yaml`](../.github/workflows/buildAndDeployKubernetes.yaml), que
construye la imagen con BuildKit, la publica en ECR con el tag `<rama>-<prefix>-<sha8>` y
hace el rollout del Deployment esperando a que quede sano.

`.github/workflows/deploy-staging.yml`:

```yaml
name: Deploy <app> (staging)

on:
  push:
    branches:
      - development
  workflow_dispatch:

concurrency:
  group: deploy-staging-<app>
  cancel-in-progress: true

permissions:
  id-token: write
  contents: read

jobs:
  deploy:
    uses: Keiron-HealthTech/ReusableWorkflow/.github/workflows/buildAndDeployKubernetes.yaml@main
    secrets: inherit
    with:
      cluster: staging
      namespace: <namespace>
      app_name: <app>
      image_repository_name: <ecr de staging que entrega tech-ops>
      runner: ubuntu-24.04-arm
      dockerfile: Dockerfile
      prefix: <app>
```

`.github/workflows/deploy-prod.yml`:

```yaml
name: Deploy <app> (prod)

on:
  push:
    branches:
      - main
  workflow_dispatch:

concurrency:
  group: deploy-prod-<app>
  cancel-in-progress: false

permissions:
  id-token: write
  contents: read

jobs:
  deploy:
    uses: Keiron-HealthTech/ReusableWorkflow/.github/workflows/buildAndDeployKubernetes.yaml@main
    secrets: inherit
    with:
      cluster: production
      namespace: <namespace>
      app_name: <app>
      image_repository_name: <ecr de producción que entrega tech-ops>
      runner: ubuntu-24.04-arm
      dockerfile: Dockerfile
      prefix: <app>
```

Reglas que no se negocian:

- `permissions: id-token: write` es obligatorio: sin él no hay token OIDC y el login a AWS falla.
- `cluster: staging` desde `development` y `cluster: production` desde `main`. El permiso OIDC
  está atado a esa rama exacta; desde otra rama el login a AWS se rechaza.
- **No pases `environment:`.** Cambia la identidad OIDC del job y el login a AWS se rechaza.
- `runner: ubuntu-24.04-arm` construye nativo para `arm64`. No uses runners self-hosted.
- En prod, `cancel-in-progress: false`: nunca cancelar un deploy a producción a la mitad.

Inputs de `buildAndDeployKubernetes.yaml`:

| Input | Obligatorio | Qué es |
|---|---|---|
| `cluster` | sí (apps nuevas) | `staging` o `production`. Activa el login por OIDC. |
| `namespace` | sí | Namespace de Kubernetes. Lo define tech-ops. |
| `app_name` | sí | Nombre del Deployment **y** de su contenedor. Lo define tech-ops. |
| `image_repository_name` | sí | Repositorio ECR del ambiente. Lo crea tech-ops. |
| `runner` | sí | `ubuntu-24.04-arm`. |
| `dockerfile` | no | Ruta del Dockerfile. Por defecto `Dockerfile`. El contexto de build es la raíz del repo. |
| `prefix` | no | Va en el tag de la imagen. Usa el nombre de la app (obligatorio en monorepos). |
| `timeout` | no | Cuánto esperar a que el rollout quede sano. Por defecto `5m`. |
| `cache_backend` | no | `gha` (por defecto) o `registry`. Usa `registry` en monorepos o builds pesados: el caché de GitHub tiene tope de 10 GB por repo. |

**Monorepo con varias apps:** un job por app (o una matriz) con su `app_name`, `dockerfile` y
`prefix`, y filtros `paths:` en el `on.push` para no desplegar lo que no cambió.

## 5. Variables de entorno y secretos

Toda la configuración de la app (secretos y variables normales) vive en **Doppler**, que
administra tech-ops. Ni el repo, ni la imagen, ni los workflows llevan valores.

- Cada variable cargada en Doppler para tu app llega al pod como **variable de entorno** con el
  mismo nombre (`DATABASE_URL` en Doppler → `process.env.DATABASE_URL`).
- Si un valor cambia en Doppler, **los pods se reinician solos con el valor nuevo**, de a poco y
  sin cortar el servicio. No tienes que hacer nada.
- Por ahora los equipos no tienen acceso a Doppler. En la solicitud mandas los **nombres** de las
  variables; los valores los coordinas directo con tech-ops, que te indica cómo entregarlos de
  forma segura. Nunca los pegues en la solicitud, Slack, issues ni prompts de IA.

Reglas para la app:

- Lee su configuración solo de variables de entorno. Nada de archivos `.env` dentro de la imagen,
  nada de `doppler run` en el Dockerfile ni en el comando de arranque, y nada de llamar a la API
  de Doppler desde la app.
- Nombres en mayúsculas con `_` (`REDIS_URL`, `API_TIMEOUT_MS`). Todos los valores llegan como
  texto: convierte números y booleanos en el código.
- **Valores multilínea** (llaves PEM, certificados): llegan con `\n` literal en vez de saltos de
  línea. Conviértelos al leerlos (por ejemplo `value.replace(/\\n/g, '\n')`) o pide que se
  guarden en base64.
- Todas las variables que la app necesita para arrancar tienen que estar cargadas **antes** del
  primer merge; si falta una, el rollout no queda sano.
- `PORT` debe coincidir con el puerto acordado con tech-ops.
- `NEW_RELIC_APP_NAME` lo define tech-ops; no lo incluyas en tu lista.
- Si un valor se filtró, avisa a tech-ops para rotarlo.

## 6. Primer deploy y verificación

1. Merge a `development`. En la pestaña Actions, el job `deploy` debe terminar en verde. Si tu
   app va solo a producción, salta al paso 4.
2. Verde significa que la imagen quedó publicada y que el rollout pasó el healthcheck dentro
   del `timeout`.
3. Si la app es pública, abre la URL de staging que te confirmó tech-ops (por ejemplo
   `https://qa.api.keiron.cl/<prefijo>/healthz`).
4. Recién con staging validado, merge a `main` y repite contra la URL de producción (por
   ejemplo `https://api.keiron.cl/<prefijo>/healthz`).

Si el rollout no queda sano, el job falla. Mientras la versión nueva no pase el healthcheck,
la anterior sigue atendiendo (el rollout es gradual), pero el rollback no es automático:
corrige y vuelve a desplegar, o avisa a tech-ops.

### Errores frecuentes

| Síntoma | Causa probable |
|---|---|
| `Not authorized to perform sts:AssumeRoleWithWebIdentity` | Falta `id-token: write`, se pasó `environment:`, la rama no es la habilitada o tech-ops aún no habilita el repo. |
| `name unknown` / `repository ... does not exist` al hacer push | `image_repository_name` mal escrito o el ECR no existe aún. |
| `deployments.apps "<app>" not found` | `app_name` o `namespace` no coinciden con lo que creó tech-ops. |
| El job queda en cola para siempre | `runner` con una etiqueta que no existe. |
| `CrashLoopBackOff` sin logs o `exec format error` | Imagen `amd64`. Ver checklist. |
| Rollout que vence el `timeout` | El healthcheck no responde: puerto distinto de `PORT`, rutas sin el prefijo acordado, falta una variable o la app no arranca. Avisa a tech-ops con el link del run. |
| Pod detenido en `Init:0/1` o `CreateContainerConfigError` | Las variables de la app aún no están en Doppler o el cluster no puede leerlas. Avisa a tech-ops. |

## 7. Qué no hacer

- Correr `kubectl`, `helm` o la consola de AWS contra los clusters, o pedir acceso para hacerlo.
- Agregar manifiestos de Kubernetes, Helm, Terraform o CDK al repo de la app.
- Usar llaves de AWS, tokens personales o `KUBECONFIG` en el repo o en los secrets de GitHub.
- Usar los workflows legacy (`buildAndChangeImage.yml`, `buildKanikoAndChangeImage.yml`,
  `buildAndChangeMatrixImage.yml`) o `buildAndDeployKubernetes.yaml` sin `cluster:`.
- Desplegar con tags `latest` o apuntar el Deployment a una imagen a mano.
- Cambiar réplicas, recursos, rutas o permisos por tu cuenta: se piden a tech-ops.

## 8. Skill para agentes de IA

La skill [`skills/deploy-eks`](../skills/deploy-eks/SKILL.md) hace que tu agente revise el repo
contra esta guía, arme los workflows y redacte la solicitud. Si la app necesita login o permisos,
instala también [`skills/keiron-auth`](../skills/keiron-auth/SKILL.md) (sección 8 de
[`auth-apps.md`](auth-apps.md)). Para instalarla en el repo de tu app:

```bash
mkdir -p .claude/skills/deploy-eks .agents/skills/deploy-eks
curl -fsSL https://raw.githubusercontent.com/Keiron-HealthTech/ReusableWorkflow/main/skills/deploy-eks/SKILL.md -o .claude/skills/deploy-eks/SKILL.md
cp .claude/skills/deploy-eks/SKILL.md .agents/skills/deploy-eks/SKILL.md
```

`.claude/skills/` la lee Claude Code y `.agents/skills/` la leen Codex y OpenCode. La skill
descarga esta guía en cada uso, así que no hace falta reinstalarla cuando la guía cambie.
Luego pídele a tu agente algo como "prepara el deploy de esta app a EKS".
