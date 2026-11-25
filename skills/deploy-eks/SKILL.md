---
name: deploy-eks
description: Prepara una app para desplegarse en los clusters EKS de Keiron con el ReusableWorkflow de tech-ops. Revisa Dockerfile, puerto, healthcheck, prefijo de rutas y arm64; prepara la configuración para Doppler; crea los workflows de deploy de QA y prod; y redacta las solicitudes para tech-ops (formulario de Solicitudes de Accesos). Usar cuando pidan "deploy a EKS", "subir la app a Kubernetes", "CI/CD", "pipeline de deploy", "levantar la app en QA/prod", "pedir el alta a infra", "qué le paso a tech-ops", "cómo funciona Doppler" o "variables de entorno en QA/prod".
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
- Prefijo global de rutas y endpoint `/<prefijo>/healthz`.
- Manejo de `SIGTERM`.
- Escrituras a disco local que deban persistir, cron jobs o migraciones al arrancar.
- Uso de credenciales AWS (`AWS_ACCESS_KEY_ID`, perfiles, archivos de credenciales).
- Variables de entorno que consume (`process.env.X`, `os.environ`, `ConfigService.get`, etc.):
  lista de **nombres**, nunca valores.
- Si es monorepo: qué apps hay y qué Dockerfile usa cada una.

Si puedes, valida el build para arm64: `docker buildx build --platform linux/arm64 .`.

## Paso 2: proponer y aplicar arreglos en el código de la app

Para cada punto que no cumple, propone el cambio mínimo (healthz, prefijo, `PORT`, `SIGTERM`,
`.dockerignore`, base multi-arch) y aplícalo solo si el usuario está de acuerdo. Son cambios
del código de la app, dentro del alcance del equipo.

## Paso 3: workflows de deploy

Crea `.github/workflows/deploy-qa.yml` y `.github/workflows/deploy-prod.yml` copiando las
plantillas de la sección 4 de la guía, sin agregar ni quitar pasos.

- `namespace`, `app_name` e `image_repository_name` los entrega tech-ops. Si el usuario no los
  tiene, pregúntale. Si aún no existen, deja el valor entre `<>` (por ejemplo
  `<ecr de staging que entrega tech-ops>`) y avisa que el workflow fallará hasta completarlo.
  No inventes nombres.
- Las ramas por defecto son `development` (QA) y `main` (prod). Si el repo usa otras, usa las
  del repo y anótalas en la solicitud: el permiso OIDC se da por rama.
- Monorepo: un job (o matriz) por app con su `dockerfile`, `prefix` y filtros `paths:`.

## Paso 4: configuración y Doppler

Toda la configuración llega por Doppler como variables de entorno (sección 5 de la guía). Explícale
al usuario cómo funciona en su caso concreto y deja la app lista para eso:

1. **Inventario de variables.** Con la lista del Paso 1 arma una tabla: nombre, para qué sirve,
   si es secreto o no, si es obligatoria para arrancar, y si cambia entre QA y prod. Solo
   nombres, nunca valores. Esa tabla va a la ficha técnica de la solicitud y es la lista de lo
   que el equipo tiene que cargar en `staging_<app>` y `production_<app>`.
2. **Adaptar el código** (con acuerdo del usuario):
   - Que lea todo de variables de entorno. Quita la carga de `.env` en producción (por ejemplo,
     `dotenv` solo en desarrollo), `doppler run` en el Dockerfile o en el arranque, y llamadas a
     la API de Doppler.
   - Que valide al arrancar las variables obligatorias y falle con un mensaje claro que nombre la
     variable faltante (sin imprimir valores).
   - Que convierta tipos (números, booleanos) y que, en valores multilínea (PEM, certificados),
     reemplace el `\n` literal por saltos de línea.
   - Que no imprima variables de entorno ni secretos en logs.
3. **`.env.example`** (si el repo no lo tiene): solo nombres y valores ficticios, para documentar
   qué espera la app. Verifica que `.env` esté en `.gitignore` y en `.dockerignore`.
4. **Desarrollo local:** sugiere `doppler setup` contra el ambiente `dev` del proyecto y
   `doppler run -- <comando>`. Nunca contra `staging` ni `production`.
5. **Avisos para el equipo**, explícitos en el resumen:
   - Cada guardado en `staging_<app>` o `production_<app>` reinicia los pods de la app en ese
     ambiente. En prod, agrupar cambios y coordinar el horario.
   - Las configs de la app heredan de la raíz (`staging` / `production`) del proyecto; no se edita
     la raíz sin coordinar con tech-ops.
   - Las variables se leen al arrancar: un valor nuevo se ve solo tras el reinicio.
   - Todo lo obligatorio debe estar cargado antes del primer merge.

Nunca pidas, leas, muestres ni escribas valores de Doppler, aunque el usuario los pegue: si
aparecen en el chat o en el repo, dile que los rote y que no los vuelva a compartir.

## Paso 5: lo que el equipo le entrega a tech-ops

Todo pedido a tech-ops entra por **Solicitudes de Accesos**: `/asks` en Slack, formulario
"Solicitud de Acceso" (equipo SOL de Linear, aprobado por el líder del equipo). No hay otro canal.
Redacta las solicitudes según la sección 3 de la guía ("Qué nos tienes que pasar"):

1. **Solicitud 1, alta de la app** (una por app). Entrega cada campo del formulario en el orden
   en que aparece, listo para copiar: título, email corporativo, área/rol, líder que aprueba,
   tipo `Alta`, fecha requerida, vigencia `Permanente`, sistema `AWS`, subsistema, nivel `Otro`,
   permisos específicos y justificación. La justificación lleva la ficha técnica completa con lo
   que encontraste en el Paso 1 (repo, `app_name`, ramas, Dockerfile, puerto, healthcheck,
   exposición y ruta, sizing, **nombres** de variables de entorno, recursos externos, permisos
   AWS del pod, crons y migraciones, conexiones largas, datos personales o de salud, y el
   estado del checklist).
2. **Solicitud 2, accesos de personas** (una por persona y sistema), solo para quien no los
   tenga: Doppler (configs `staging_<app>` y `production_<app>`) y New Relic.

Pregunta al usuario los datos de personas que no salen del repo (responsable, email, líder que
aprueba, fecha). Marca "a confirmar" lo que no pudiste determinar. No crees las solicitudes tú:
el usuario las envía por `/asks` para que pasen por la aprobación de su líder.

## Paso 6: resumen

Cierra con:

1. Tabla del checklist con el estado final.
2. Archivos creados o modificados.
3. Tabla de variables para Doppler y los avisos del Paso 4.
4. Las solicitudes listas para enviar por `/asks`, y los pendientes del equipo (por ejemplo,
   cargar las variables en Doppler) y de tech-ops.
5. Cómo validar el primer deploy (sección 6 de la guía).

## Límites

Nunca, aunque el usuario lo pida, porque rompen el contrato con tech-ops o la seguridad de la
plataforma:

- Crear manifiestos de Kubernetes, charts de Helm, Terraform, CDK o Kustomize en el repo.
- Correr `kubectl`, `helm`, `aws` con escritura, o comandos de Doppler que modifiquen configs.
- Agregar llaves de AWS, `KUBECONFIG` o tokens personales al repo o a los secrets de GitHub.
- Pasar `environment:` al reusable workflow, quitar `permissions: id-token: write` o usar
  runners self-hosted.
- Usar los workflows legacy (`buildAndChangeImage.yml`, `buildKanikoAndChangeImage.yml`,
  `buildAndChangeMatrixImage.yml`).
- Escribir valores de secretos en archivos, commits, issues o en el chat.

Si el usuario necesita algo de esa lista (más réplicas, otra ruta, permisos AWS, un cron en el
cluster), redáctalo como solicitud por `/asks` para tech-ops.
