# n8n + PostgreSQL Docker Setup

Entorno local completo de n8n con base de datos PostgreSQL, respaldado por runners externos (modelo de ejecución recomendado).

## Estructura

```
.
├── docker-compose.yml      # Configuración de servicios
├── scripts/                # Scripts de utilidad
│   ├── init-data.sh        # Inicialización de DB (Postgres)
│   └── update-n8n.sh       # Script de actualización y backup
├── .env                    # Variables de entorno (con secretos)
├── .env.example            # Template para .env (sin secretos)
├── backups/                # Directorio de respaldos automáticos
└── .gitignore              # Exclusión de archivos sensibles
```

## Servicios

- **postgres:16** — Base de datos PostgreSQL con volumen persistente
- **n8n** — Interfaz web y API en `http://localhost:5678`
- **n8n-runner** — Task runner externo (recomendado para ejecución de workflows)

## Primeros pasos

### 1. Editar credenciales

Abre `.env` y reemplaza los valores `CHANGE_ME_*`:

```env
POSTGRES_PASSWORD=tu_password_fuerte_aqui
POSTGRES_NON_ROOT_PASSWORD=tu_password_usuario_aqui
RUNNERS_AUTH_TOKEN=token_aleatorio_aqui
N8N_ENCRYPTION_KEY=32_caracteres_aleatorios_aqui
```

**Importante:** `N8N_ENCRYPTION_KEY` debe ser una cadena de ≥32 caracteres. Generarla con:
```bash
openssl rand -hex 16
```

### 2. Arrancar los servicios

```bash
docker-compose up -d
```

Ver logs en tiempo real:
```bash
docker-compose logs -f n8n
```

### 3. Acceder a n8n

```
http://localhost:5678
```

La primera vez te pedirá crear una cuenta de usuario.

## Comandos útiles

```bash
# Ver estado de servicios
docker-compose ps

# Detener servicios
docker-compose stop

# Detener y eliminar volúmenes (⚠️ borra datos)
docker-compose down -v

# Ver logs detallados
docker-compose logs n8n
docker-compose logs postgres

# Acceder a la terminal de Postgres
docker-compose exec postgres psql -U n8n_admin -d n8n

# Actualizar imágenes Docker (manual)
docker-compose pull
docker-compose up -d

# Actualizar usando el script (recomendado: hace backup previo)
./scripts/update-n8n.sh
```

## Variables de entorno

| Variable | Descripción |
|----------|------------|
| `N8N_VERSION` | Versión de n8n (`stable` = última) |
| `POSTGRES_USER` | Usuario admin de Postgres |
| `POSTGRES_PASSWORD` | Contraseña del admin |
| `POSTGRES_DB` | Nombre de la base de datos |
| `POSTGRES_NON_ROOT_USER` | Usuario no-root para n8n |
| `POSTGRES_NON_ROOT_PASSWORD` | Contraseña del usuario no-root |
| `RUNNERS_AUTH_TOKEN` | Token de autenticación del task runner |
| `N8N_ENCRYPTION_KEY` | Clave para encriptar credenciales guardadas |

## Volúmenes

- `db_storage` → `/var/lib/postgresql/data` — Datos de Postgres
- `n8n_storage` → `/home/node/.n8n` — Configuración, encryption key, logs de n8n

## Puertos

- `5678` → n8n web UI y API
- `5679` → n8n task runner broker (solo red interna)
- `5432` → PostgreSQL (solo red interna)

## Notas importantes

1. **PostgreSQL solo es accesible dentro de Docker** — no está expuesto al host
2. **No perder la encryption key** — si se pierde, las credenciales guardadas serán irrecuperables
3. **El usuario Postgres para n8n es no-root** — esto sigue las mejores prácticas de seguridad
4. **Los datos persisten** — incluso si paras los contenedores, los volúmenes conservan los datos

## Solución de problemas

### n8n tarda en arrancar o dice "unhealthy"
Espera a que PostgreSQL esté listo. Ver logs:
```bash
docker-compose logs postgres
```

### "Connection refused" desde n8n a Postgres
Verifica que `DB_POSTGRESDB_HOST=postgres` en el compose (es el nombre del servicio, no `localhost`).

### Olvidé la encryption key
Si la pierdes y necesitas resetear:
```bash
docker-compose down -v
```
Esto borra todos los datos. Luego, vuelve a crear credenciales desde cero.

## Referencias

- [n8n Docker Docs](https://docs.n8n.io/hosting/installation/docker/)
- [n8n Database Config](https://docs.n8n.io/hosting/configuration/environment-variables/database/)
- [n8n-hosting GitHub](https://github.com/n8n-io/n8n-hosting)
