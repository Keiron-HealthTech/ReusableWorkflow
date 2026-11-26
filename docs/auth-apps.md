# Login y permisos para apps nuevas

Guía para los equipos cuya app necesita que los usuarios inicien sesión, o una API que necesita
saber quién la llama y qué puede hacer. Complementa la guía de despliegue
([`nueva-app-eks.md`](nueva-app-eks.md)).

Si trabajas con un agente de IA, instala la skill de la sección 8: revisa tu repo, te ayuda a
integrar el login y los permisos, y te deja lista la solicitud para tech-ops.

## 1. Cómo funciona

Keirón tiene dos servicios centrales, administrados por tech-ops:

- **Autenticación:** cuentas de usuario, contraseñas y segundo factor (2FA). El login entrega un
  **token JWT** (bearer) con vencimiento. No hay refresh token: cuando vence, el usuario vuelve a
  iniciar sesión.
- **Autorización:** roles y permisos. Un permiso es una **acción** sobre un **recurso**, por
  ejemplo `read` sobre `crm:deal`. Los roles agrupan permisos y se asignan a usuarios. Tu app
  pregunta "¿este token puede hacer `<acción>` sobre `<recurso>`?" y recibe sí o no.

Tu app **no guarda usuarios ni contraseñas, ni administra roles**: le pregunta a estos servicios.
Los equipos no tienen acceso al código ni a las bases de datos de auth; todo lo que necesites de
ellos se pide a tech-ops (sección 5).

## 2. Elige tu caso

| Caso | Cuándo | Ejemplo |
|---|---|---|
| **A. App web con login** | La app tiene su propia pantalla de login (panel, backoffice). | Un panel interno en Next.js |
| **B. API con token** | La app recibe requests de un front u otro sistema que ya trae un token. | Una API NestJS que consume un front existente |

Una app puede ser las dos cosas (un panel con su propio backend): aplica A para el login y B para
proteger cada endpoint.

### Caso A: app web con login

1. El formulario de login le envía email y contraseña **a tu backend**, nunca directo al
   servicio de auth desde el navegador.
2. Tu backend llama a `POST <AUTH_SERVICE_URL>/authentication/login` con
   `{ email, password, application: <valor de <APP>_APPLICATION> }`:
   - Si responde `{ twoFactorAuth: true }`, pide el código al usuario y reintenta agregando
     `twoFaCode`.
   - Credenciales incorrectas: `400` con `{ "error": "Invalid credentials" }`. Cualquier otro
     error es de configuración: regístralo como error, no lo muestres como "contraseña
     incorrecta".
   - Login correcto: `{ accessToken, tokenType, expiresIn, user }`. `expiresIn` viene en
     segundos y como texto.
   - Las respuestas correctas vienen envueltas en `{ data, success }`; los errores no.
3. Con el token, tu backend valida que el usuario tenga acceso a la app:
   `POST <PLATFORM_AUTHORIZATION_URL>/check-permissions` con el header
   `Authorization: Bearer <token>` y `{ resource, action }` (por ejemplo
   `{ "resource": "<app>:panel", "action": "act" }`). Responde `{ can: true | false }`, también
   envuelto en `{ data, success }`. Si no es `true`, responde `403` y no crees la sesión.
4. Guarda el token en una **sesión del lado del servidor**: cookie cifrada, `httpOnly`, `secure`,
   `sameSite=lax`, que vence junto con el token. El token nunca llega al navegador (nada de
   `localStorage` ni de variables `NEXT_PUBLIC_*`).
5. Para cada acción sensible (editar, borrar, exportar), vuelve a consultar `check-permissions`
   con el recurso y la acción concretos. El acceso de entrada no da permiso para todo.
6. Logout: borra la sesión. El token no se revoca en el servicio; por eso la sesión no debe durar
   más que el token.

### Caso B: API con token

1. Toda ruta, salvo el healthcheck, exige `Authorization: Bearer <token>`.
2. Verifica el token: firma HS256 con `JWT_SECRET` y vencimiento. Sin firma válida, vencido o sin
   `id` de usuario: `401`. Nunca leas el contenido de un token sin verificar la firma.
3. Cada endpoint declara qué permiso exige y lo consulta en `check-permissions` (acción y recurso,
   y `context` si el permiso depende de una entidad, por ejemplo un ID). Sin permiso: `403`. Una
   ruta sin permiso declarado tiene que responder `403` por defecto, no quedar abierta.
4. **Falla cerrado:** si el servicio de autorización no responde (timeout de unos 3 s), responde
   `503` sin entregar datos. Nunca "dejar pasar" porque auth no contesta.
5. Opcional: cachea la decisión por usuario y consulta unos segundos (30 s como máximo) para no
   consultar en cada request.
6. Si otro sistema (un ETL, otro backend) llama a tu API, ese sistema usa un **usuario de
   servicio** propio con permisos mínimos, que se pide a tech-ops. Nunca el token de una persona.

## 3. Diseña tus permisos

Antes de pedir nada, define la tabla de permisos de tu app. Mientras más chica, mejor: cada
persona recibe solo lo que necesita.

- **Recursos:** `<app>:<cosa>` en minúscula, por ejemplo `facturacion:panel`,
  `facturacion:invoice`.
- **Acciones:** `read`, `create`, `update`, `delete`, `act` (entrar o ejecutar algo) y `manage`
  (todo; úsala poco).
- **Roles:** combinaciones con nombre, por ejemplo:

| Rol | Permisos |
|---|---|
| `<App> lector` | `act` sobre `<app>:panel`, `read` sobre `<app>:invoice` |
| `<App> editor` | lo del lector, más `create` y `update` sobre `<app>:invoice` |

## 4. Variables de entorno

Los valores los carga tech-ops en Doppler (ver la sección 5 de la guía de despliegue); en el repo
solo van los nombres, en `.env.example`.

| Variable | Caso | Para qué |
|---|---|---|
| `AUTH_SERVICE_URL` | A | Base del servicio de autenticación |
| `<APP>_APPLICATION` | A | Identificador de aplicación que se envía en el login (ej. `FACTURACION_APPLICATION`). Lo entrega tech-ops. |
| `PLATFORM_AUTHORIZATION_URL` | A y B | Base del servicio de autorización |
| `SESSION_SECRET` | A | Clave de la cookie de sesión |
| `JWT_SECRET` | B | Clave para verificar la firma del token |

El nombre de las variables propias (recursos y acciones que consulta tu app) lo eliges tú; si son
fijas, pueden ir en el código.

Si falta alguna en producción, la app **no debe arrancar** (falla con un mensaje que nombre la
variable). En desarrollo local puedes usar un usuario de prueba cuando `AUTH_SERVICE_URL` no está
definida, pero ese atajo tiene que ser imposible de activar en producción.

## 5. Qué nos tienes que pasar

Como todo pedido a tech-ops, entra por **Solicitudes de Accesos** (`/asks` en Slack, formulario
"Solicitud de Acceso"). Es una solicitud aparte de la de despliegue.

| Campo | Qué poner |
|---|---|
| Título | `<Nombre Apellido del responsable> - Auth <app>` |
| Tipo | `Alta` |
| Vigencia | `Permanente` |
| Sistema | `Auth Keirón` |
| Subsistema, módulo o recurso | `Login y permisos de <app>` |
| Nivel de acceso | `Otro` |
| Permisos específicos | `Registrar <app> en autenticación y crear sus roles y permisos` |
| Justificación | La ficha de abajo, completa |

Los demás campos (email, área, líder que aprueba, fecha) igual que en la guía de despliegue.

```markdown
Qué hace la app y quién la usa: <una o dos frases>

- Repo: Keiron-HealthTech/<repo>
- Caso: A (login propio) | B (API con token) | ambos
- Ambientes: staging y prod | solo prod
- Quién inicia sesión: <equipo interno | clientes | ...> ¿2FA obligatorio?: <sí/no>
- Quién llama a la API (caso B): <qué front o sistema; ¿necesita usuario de servicio?>
- Recursos y acciones: <tabla de la sección 3>
- Roles propuestos: <tabla de la sección 3>
- Usuarios iniciales por rol: <email → rol>
- ¿Datos personales o de salud detrás del login?: <sí/no, cuáles>
```

tech-ops evalúa la solicitud, registra la app, crea los roles, carga las variables y te responde
en la misma solicitud. Las cuentas que no existan se crean en ese momento (no hay registro
abierto).

**Después del alta**, cada vez que alguien necesite entrar a tu app o cambiar de rol, esa persona
(o su líder) envía una Solicitud de Acceso con Sistema `<app>`, el rol que necesita y para qué.
Las bajas también: cuando alguien deja de necesitar el acceso, se pide la baja. Así cada acceso
queda aprobado y registrado.

## 6. Verificación

1. Un usuario con rol entra y ve solo lo que su rol permite.
2. Un usuario sin rol recibe `403` y no obtiene sesión.
3. Credenciales incorrectas muestran "credenciales incorrectas"; un error de configuración queda
   en los logs como error.
4. Caso B: un request sin token, con token vencido o con firma alterada recibe `401`.
5. Ni el token ni las contraseñas aparecen en los logs.

## 7. Qué no hacer

- Crear una tabla de usuarios o contraseñas propia, o usar otro proveedor de login.
- Decidir permisos en el código por el email, el dominio o una lista fija de personas.
- Mandar el token al navegador o guardarlo en `localStorage`.
- Leer el token sin verificar la firma, o dejar pasar requests si auth no responde.
- Registrar tokens, contraseñas o códigos 2FA en logs.
- Usar el identificador de aplicación, los roles o el usuario de servicio de otra app.
- Pedir acceso al repo o a las bases de datos de auth: todo se pide por solicitud.

## 8. Skill para agentes de IA

La skill [`skills/keiron-auth`](../skills/keiron-auth/SKILL.md) revisa tu repo contra esta guía,
te ayuda a implementar el caso que corresponda y redacta la solicitud. Para instalarla en el repo
de tu app:

```bash
mkdir -p .claude/skills/keiron-auth .agents/skills/keiron-auth
curl -fsSL https://raw.githubusercontent.com/Keiron-HealthTech/ReusableWorkflow/main/skills/keiron-auth/SKILL.md -o .claude/skills/keiron-auth/SKILL.md
cp .claude/skills/keiron-auth/SKILL.md .agents/skills/keiron-auth/SKILL.md
```

Luego pídele a tu agente algo como "agrega login con la auth de Keirón a esta app".
