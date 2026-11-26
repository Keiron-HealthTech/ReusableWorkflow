---
name: deploy-eks
description: Prepara una app para desplegarse en los clusters EKS de Keiron con el ReusableWorkflow de tech-ops. Revisa Dockerfile, puerto, healthcheck, prefijo de rutas y arm64; prepara las variables de entorno; crea los workflows de deploy de staging y prod; y redacta la solicitud para tech-ops (formulario de Solicitudes de Accesos). Usar cuando pidan "deploy a EKS", "subir la app a Kubernetes", "CI/CD", "pipeline de deploy", "levantar la app en staging/QA/prod", "pedir el alta a infra", "qué le paso a tech-ops", "cómo funciona Doppler" o "variables de entorno en staging/prod".
---

# deploy-eks

Prepara el repo actual para desplegarse en EKS siguiendo el contrato de tech-ops. El repo de la
app solo construye y publica la imagen; tech-ops levanta todo lo que corre en el cluster.

## Paso 0: cargar la guía vigente

La guía es la fuente de verdad y cambia con el tiempo. Descárgala antes de hacer nada:

```bash
curl -fsSL https://raw.githubusercontent.com/Keiron-HealthTech/ReusableWorkflow/main/docs/nueva-app-eks.md
```

Si la guía contradice algo de esta skill, manda la guía. Si no puedes descargarla, dilo y
detente: no trabajes de memoria.

## Paso 1: diagnosticar el repo

Lee el repo y arma una tabla con el checklist de la sección 3 de la guía (cumple / no cumple /
no se puede determinar, con la evidencia: archivo y línea). Como mínimo:

- Dockerfile: imagen base multi-arch, multi-stage, `.dockerignore`, usuario no root, `CMD` en
  forma exec, sin `.env` ni secretos copiados.
- Puerto: la app lee `PORT` y escucha en `0.0.0.0`.
- Prefijo global de rutas (o si puede servir desde la raíz con subdominio propio) y endpoint
  `healthz`.
- Manejo de `SIGTERM`.
- Escrituras a disco local que deban persistir, cron jobs o migraciones al arrancar.
- Uso de credenciales AWS (`AWS_ACCESS_KEY_ID`, perfiles, archivos de credenciales).
- Variables de entorno que consume (`process.env.X`, `os.environ`, `ConfigService.get`, etc.):
  lista de **nombres**, nunca valores.
- Si es monorepo: qué apps hay y qué Dockerfile usa cada una.
- Ambientes: si la app tiene recursos de staging (base, APIs, colas) a los que conectarse. Si no
  los tiene, va solo a producción. Una app en staging nunca se conecta a recursos de prod: si
  ves URLs o credenciales de prod en la config de staging, márcalo como bloqueante.

- Auth: si la app tiene login, rutas privadas o una API que deba saber quién la llama. Si es así,
  esa parte se resuelve con la skill `keiron-auth` (o la guía `docs/auth-apps.md` del mismo
  repo si no está instalada): no implementes login, usuarios ni roles por tu cuenta, y la
  solicitud de auth va aparte.

Si puedes, valida el build para arm64: `docker buildx build --platform linux/arm64 .`.

## Paso 2: proponer y aplicar arreglos en el código de la app

Para cada punto que no cumple, propone el cambio mínimo (healthz, prefijo, `PORT`, `SIGTERM`,
`.dockerignore`, base multi-arch) y aplícalo solo si el usuario está de acuerdo. Son cambios
del código de la app, dentro del alcance del equipo.

## Paso 3: workflows de deploy

Crea `.github/workflows/deploy-staging.yml` y `.github/workflows/deploy-prod.yml` copiando las
plantillas de la sección 4 de la guía, sin agregar ni quitar pasos. Si la app va solo a
producción, crea solo `deploy-prod.yml`.

- `namespace`, `app_name` e `image_repository_name` los entrega tech-ops. Si el usuario no los
  tiene, pregúntale. Si aún no existen, deja el valor entre `<>` (por ejemplo
  `<ecr de staging que entrega tech-ops>`) y avisa que el workflow fallará hasta completarlo.
  No inventes nombres.
- Las ramas por defecto son `development` (staging) y `main` (prod). Si el repo usa otras, usa las
  del repo y anótalas en la solicitud: el permiso OIDC se da por rama.
- Monorepo: un job (o matriz) por app con su `dockerfile`, `prefix` y filtros `paths:`.

## Paso 4: variables de entorno

Toda la configuración llega como variables de entorno desde Doppler, que administra tech-ops
(sección 5 de la guía). El equipo no tiene acceso a Doppler: entrega los nombres en la solicitud
y coordina los valores directo con tech-ops. Deja la app lista para eso:

1. **Inventario de variables.** Con la lista del Paso 1 arma una tabla: nombre, para qué sirve,
   si es secreto o no, si es obligatoria para arrancar, y si cambia entre staging y prod. Solo
   nombres, nunca valores. Esa tabla va a la ficha técnica de la solicitud.
2. **Adaptar el código** (con acuerdo del usuario):
   - Que lea todo de variables de entorno. `dotenv` y similares están bien (por defecto no
     pisan variables ya definidas); lo que no va es un archivo `.env` copiado a la imagen o
     commiteado, `override: true` o equivalentes que pisen el entorno, `doppler run` en el
     Dockerfile o en el arranque, y llamadas a la API de Doppler.
   - Que valide al arrancar las variables obligatorias y falle con un mensaje claro que nombre la
     variable faltante (sin imprimir valores).
   - Que convierta tipos (números, booleanos) y que, en valores multilínea (PEM, certificados),
     reemplace el `\n` literal por saltos de línea.
   - Que no imprima variables de entorno ni secretos en logs.
3. **`.env.example`** (si el repo no lo tiene): solo nombres y valores ficticios, para documentar
   qué espera la app. Verifica que `.env` esté en `.gitignore` y en `.dockerignore`.
4. **Avisos para el equipo**, explícitos en el resumen:
   - Los valores se coordinan con tech-ops antes del primer merge; si falta una variable
     obligatoria, el rollout no queda sano.
   - Cuando un valor cambia en Doppler, los pods se reinician solos con el valor nuevo, de forma
     gradual y sin cortar el servicio.

Nunca pidas, leas, muestres ni escribas valores de secretos, aunque el usuario los pegue: si
aparecen en el chat o en el repo, dile que avise a tech-ops para rotarlos.

## Paso 5: lo que el equipo le entrega a tech-ops

Todo pedido a tech-ops entra por **Solicitudes de Accesos**: `/asks` en Slack, formulario
"Solicitud de Acceso" (equipo SOL de Linear, aprobado por el líder del equipo). No hay otro canal.
Redacta la solicitud según la sección 3 de la guía ("Qué nos tienes que pasar"):

1. **Solicitud 1, alta de la app** (una por app). Entrega cada campo del formulario en el orden
   en que aparece, listo para copiar: título, email corporativo, área/rol, líder que aprueba,
   tipo `Alta`, fecha requerida, vigencia `Permanente`, sistema `AWS`, subsistema, nivel `Otro`,
   permisos específicos y justificación. La justificación lleva la ficha técnica completa con lo
   que encontraste en el Paso 1 (repo, `app_name`, ambientes, recursos de staging, ramas,
   Dockerfile, puerto, healthcheck, exposición, sizing, **nombres** de variables de entorno,
   recursos externos, permisos AWS del pod, crons y migraciones, conexiones largas, datos
   personales o de salud, y el estado del checklist).
2. **Solicitud 2, accesos de personas**: no la redactes por defecto. Solo si el usuario dice que
   alguien necesita ver logs y métricas en New Relic, con la justificación de para qué; queda
   sujeta a evaluación de tech-ops. Doppler no se pide.

Pregunta al usuario los datos de personas que no salen del repo (responsable, email, líder que
aprueba, fecha). Marca "a confirmar" lo que no pudiste determinar. No crees las solicitudes tú:
el usuario las envía por `/asks` para que pasen por la aprobación de su líder.

## Paso 6: resumen

Cierra con:

1. Tabla del checklist con el estado final.
2. Archivos creados o modificados.
3. Tabla de variables y los avisos del Paso 4.
4. La solicitud lista para enviar por `/asks` (y, si la app necesita auth, el aviso de que falta
   la solicitud de auth con la skill `keiron-auth`), y los pendientes del equipo (por ejemplo,
   coordinar los valores de las variables con tech-ops) y de tech-ops.
5. Cómo validar el primer deploy (sección 6 de la guía).

## Límites

Nunca, aunque el usuario lo pida, porque rompen el contrato con tech-ops o la seguridad de la
plataforma:

- Crear manifiestos de Kubernetes, charts de Helm, Terraform, CDK o Kustomize en el repo.
- Correr `kubectl`, `helm`, `aws` con escritura, o comandos de Doppler.
- Agregar llaves de AWS, `KUBECONFIG` o tokens personales al repo o a los secrets de GitHub.
- Pasar `environment:` al reusable workflow, quitar `permissions: id-token: write` o usar
  runners self-hosted.
- Usar los workflows legacy (`buildAndChangeImage.yml`, `buildKanikoAndChangeImage.yml`,
  `buildAndChangeMatrixImage.yml`).
- Escribir valores de secretos en archivos, commits, issues o en el chat.

Si el usuario necesita algo de esa lista (más réplicas, otra ruta, permisos AWS, un cron en el
cluster), redáctalo como solicitud por `/asks` para tech-ops.
