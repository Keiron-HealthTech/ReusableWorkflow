---
name: keiron-auth
description: Integra una app con la autenticación y los permisos centrales de Keirón (login con token JWT y permisos por rol administrados por tech-ops). Revisa el repo, diseña la tabla de permisos, implementa el login (app web) o la protección de endpoints (API), y redacta la solicitud para tech-ops. Usar cuando pidan "login", "autenticación", "auth", "permisos", "roles", "proteger la API", "quién puede entrar a la app", "agregar usuarios a la app" o "keiron-authentication".
---

# keiron-auth

Integra el repo actual con la auth central de Keirón siguiendo el contrato de tech-ops. La app
consulta los servicios de autenticación y autorización; no guarda usuarios ni administra roles.
El equipo no tiene acceso al repo ni a las bases de datos de auth: lo que haga falta se pide a
tech-ops.

## Paso 0: cargar la guía vigente

```bash
curl -fsSL https://raw.githubusercontent.com/Keiron-HealthTech/ReusableWorkflow/main/docs/auth-apps.md
```

Si la guía contradice algo de esta skill, manda la guía. Si no puedes descargarla, dilo y
detente: no trabajes de memoria.

## Paso 1: diagnosticar

Lee el repo y responde, con evidencia (archivo y línea):

- **¿Necesita auth?** Pantallas de login, rutas privadas, endpoints con datos no públicos. Si no
  necesita, dilo y termina.
- **Caso:** A (app web con login propio), B (API que recibe un token) o ambos (sección 2 de la
  guía).
- **Auth existente** que haya que reemplazar: tabla de usuarios o contraseñas propia,
  `passport-local`, NextAuth/Auth.js con proveedores propios, Cognito, Firebase, Auth0, listas de
  emails en el código, tokens en `localStorage`, decodificación de JWT sin verificar firma.
- **Rutas y acciones** que hay que proteger: lista de pantallas y endpoints con lo que hacen
  (leer, crear, editar, borrar, exportar).
- **Quién llama a la API** si es caso B: qué front o sistema, y si es una persona o una máquina.

## Paso 2: diseñar los permisos con el usuario

Propón la tabla de la sección 3 de la guía (recursos `<app>:<cosa>`, acciones, roles) a partir
de las rutas del Paso 1. Mínimo privilegio: pocos roles, sin `manage` salvo que se justifique.
Pregunta al usuario qué roles hay en la práctica y quién está en cada uno. No avances sin que la
apruebe.

## Paso 3: implementar (con acuerdo del usuario)

Sigue la sección 2 de la guía al pie de la letra para el caso que corresponda:

- **Caso A:** login desde el backend, manejo de 2FA (`twoFaCode`), distinción entre
  `400 Invalid credentials` y errores de configuración, gate con `check-permissions`, sesión en
  cookie cifrada `httpOnly` que vence con el token, chequeo de permisos por acción sensible,
  logout que borra la sesión. Desenvuelve `{ data, success }` aceptando también la forma plana.
- **Caso B:** guard que verifica firma HS256 con `JWT_SECRET` y vencimiento, permiso declarado
  por endpoint (decorador o middleware) con `403` por defecto si falta, consulta a
  `check-permissions` con timeout y fallo cerrado (`503`), caché corta opcional.

Además, en ambos casos:

- Validar al arrancar las variables de la sección 4 y fallar con un mensaje que nombre la que
  falta. Un modo de desarrollo sin auth solo si `AUTH_SERVICE_URL` no está definida y nunca en
  producción.
- `.env.example` con los nombres de la sección 4 y valores ficticios.
- Ningún token, contraseña ni código 2FA en logs.
- Tests: usuario con permiso, sin permiso (`403`), sin token o token alterado (`401`, caso B),
  auth caído (`503`, caso B).

Usa el framework que ya tiene el repo; no agregues dependencias si el framework resuelve lo
mismo.

## Paso 4: solicitud para tech-ops

Redacta la solicitud de la sección 5 de la guía, campo por campo y lista para copiar, con la
ficha completa: caso, ambientes, quién inicia sesión, 2FA, quién llama a la API, la tabla de
permisos y roles aprobada en el Paso 2, usuarios iniciales por rol y si hay datos personales o de
salud. Pregunta los datos que no salen del repo (responsable, email, líder que aprueba, fecha) y
marca "a confirmar" lo que no sepas. El usuario la envía por `/asks`; tú no.

Explica también que, después del alta, cada persona que necesite entrar o cambiar de rol (y cada
baja) va en su propia Solicitud de Acceso con Sistema `<app>`.

## Paso 5: resumen

1. Caso de la app y qué se implementó (archivos creados o modificados).
2. Tabla de permisos y roles.
3. Variables que tech-ops tiene que cargar (solo nombres).
4. La solicitud lista para enviar y los pendientes.
5. Cómo verificar (sección 6 de la guía).

## Límites

Nunca, aunque el usuario lo pida:

- Pedir, leer, mostrar o escribir valores de `JWT_SECRET`, `SESSION_SECRET`, tokens o
  contraseñas. Si aparecen en el chat o en el repo, dile que avise a tech-ops para rotarlos.
- Crear usuarios, roles o permisos tú mismo, o escribir en bases de datos de auth.
- Crear una tabla de usuarios propia o un login alternativo.
- Decidir permisos por email, dominio o listas fijas en el código.
- Dejar pasar requests cuando el servicio de autorización no responde.
- Reutilizar el identificador de aplicación, los roles o el usuario de servicio de otra app.
