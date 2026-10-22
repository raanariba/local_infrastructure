# Flujo local para repositorios PHP y Laravel

Esta guía describe cómo preparar y ejecutar **en desarrollo local** una aplicación PHP o Laravel ubicada en `repositorios/`. Cada aplicación conserva su propio Git, `composer.json`, `composer.lock`, archivos de entorno, migraciones, pruebas y comandos. La infraestructura raíz proporciona servicios compartidos y, en esta rama, PHP CLI 8.3.6. No despliega aplicaciones a producción.

## Compatibilidad antes de iniciar

1. Consulte el `composer.json`, el `composer.lock` y el README de la aplicación para confirmar su versión de Laravel, los requisitos de PHP y los servicios que utiliza. `php -v` confirma únicamente el intérprete seleccionado; no demuestra que la aplicación sea compatible.
2. Laravel 8 tiene como rango de PHP soportado oficialmente 7.3–8.1 y dejó de recibir correcciones de seguridad el 24 de enero de 2023. PHP 8.3.6 de esta rama queda fuera de ese rango. Si una aplicación sigue en Laravel 8, registre y pruebe la incompatibilidad como trabajo pendiente, y planifique actualizar Laravel y sus dependencias. No considere una instalación exitosa o `artisan serve` como validación de seguridad ni como autorización para producción.
3. No fuerce la instalación de dependencias con `--ignore-platform-reqs` para ocultar incompatibilidades. Mantenga `composer.lock` bajo control de versiones en el repositorio de la aplicación y revise los cambios de dependencias por separado.

Fuentes: [soporte de Laravel 8](https://laravel.com/docs/8.x/releases), [requisitos de despliegue de Laravel 8](https://laravel.com/docs/8.x/deployment).

## Preparación de la infraestructura

Desde la raíz de `local-infrastructure`, ejecute una sola vez `bash ./setup-local.sh`. Incluya `--with-mysql`, `--with-postgres` o `--with-redis` solo si la aplicación necesita esos servicios. El script prepara PHP, crea el `.env` privado de infraestructura e inicia los contenedores compartidos. Si la pila ya está configurada y detenida, use `docker compose up -d` desde la raíz; al usar servicios opcionales, incluya los mismos archivos `-f` con los que fueron iniciados. Compruebe su estado con `docker compose ps` y los mismos archivos Compose opcionales cuando correspondan.

Clone cada aplicación en `repositorios/<nombre>` según su propia documentación. La infraestructura no instala sus dependencias ni comparte automáticamente las contraseñas de su `.env` con la aplicación.

### Comprobación y reparación de PHP al actualizar

`bash ./update-local.sh` comprueba primero el ejecutable de PHP aislado y su versión exacta, 8.3.6. Si la comprobación falla, reutiliza `enviroment/setup-phpenv.sh` para instalarlo o reconstruirlo, y solo continúa con los repositorios y servicios después de validarlo de nuevo. No reinstala una versión correcta ni cambia el PHP del sistema u otras versiones de phpenv.

La reparación necesita Git, Docker Engine accesible y Ubuntu 22.04+ o Debian 12+, con glibc 2.35+ y arquitectura x86_64 o aarch64; `--skip-services` omite el inicio de servicios, no esta comprobación ni la reparación. Antes de sustituir una instalación existente, la mueve a `enviroment/phpenv/.php-8.3.6-backup.*/previous`. Conserva ese respaldo después de una reparación correcta. Si falla, intenta restaurarlo, conserva la instalación fallida en ese mismo directorio de respaldo cuando exista y detiene la actualización antes de modificar repositorios o servicios. No use `--force` para reparar PHP: esa opción descarta cambios de los repositorios.

En otra estación de trabajo, clone esta rama y ejecute primero `bash ./setup-local.sh`; después use `bash ./update-local.sh`. No traslade `.env` ni `enviroment/phpenv/` entre máquinas. El setup genera credenciales nuevas y compila PHP para la arquitectura de destino usando siempre `ubuntu:22.04`, en lugar de elegir las bibliotecas de la versión local de Ubuntu o Debian. Comprueba la compatibilidad del host antes de instalar. La reparación puede instalar PHP y phpenv si faltan, pero el actualizador no sustituye la preparación inicial de Git, Docker y los servicios.

Cada compilación conserva su salida en `enviroment/phpenv/logs/php-8.3.6.*/build.log` y los diagnósticos de php-build en ese mismo directorio, fuera del contenedor temporal. El log identifica el compilador, libxml2 y OpenSSL utilizados. Si falla, se indica la ruta local y se muestran los primeros errores del compilador. Estos archivos están ignorados por Git; revíselos antes de compartirlos. Para reducir el uso de memoria, configure `PHP_BUILD_JOBS=1` en la invocación; el valor predeterminado es 2 y debe ser un entero positivo.

Después de actualizar los scripts en una estación donde falló la instalación, puede reparar solo PHP sin actualizar aplicaciones ni iniciar servicios:

```bash
PHP_BUILD_JOBS=1 bash ./enviroment/setup-phpenv.sh
source ./enviroment/activate.sh
php --version
```

No desinstale el PHP del sistema. La activación afecta únicamente a la terminal actual y debe hacerse después de que la instalación aislada termine correctamente.

## Aplicación Laravel ejecutada en el host

Este ejemplo se aplica **solo después de confirmar la compatibilidad** de la aplicación con PHP 8.3.6 y sus dependencias. Ejecútelo desde la raíz de la infraestructura:

```bash
source ./enviroment/activate.sh
php -v
cd repositorios/NOMBRE_DEL_REPOSITORIO
# Configure el .env privado de la aplicación según su README.
composer install
php artisan serve --host=127.0.0.1
```

Sustituya `NOMBRE_DEL_REPOSITORIO` por la carpeta real. `activate.sh` selecciona PHP solo en la terminal actual; no inicia Docker ni la aplicación. El repositorio de la aplicación debe configurar su propio `.env` antes de iniciar Artisan. En una instalación local nueva, genere `APP_KEY` únicamente si todavía no existe, siguiendo el README de esa aplicación; cambiar una clave existente puede invalidar sesiones y datos cifrados. Configure los servicios compartidos con `127.0.0.1` y los puertos publicados indicados en el `.env` de infraestructura. Mantenga las credenciales en el `.env` privado de la aplicación, sin copiarlas a archivos versionados.

Ejecute `php artisan migrate` solo cuando la aplicación lo requiera, después de verificar la base de datos de destino y revisar sus migraciones. Si la aplicación tiene un frontend, use el gestor de paquetes y los scripts declarados por **esa aplicación**. Pruebas, colas, tareas programadas y otros procesos también se ejecutan conforme a su README. `php artisan serve` sirve para desarrollo local; no es un proceso de producción.

Para salir del PHP de esta rama, ejecute `deactivate_phpenv` en la misma terminal.

## Aplicación ejecutada en contenedores

Inicie la aplicación con el Compose de su propio repositorio y únala a `LOCAL_INFRA_NETWORK` como red externa. Su configuración debe usar nombres de servicio y puertos internos, por ejemplo `mysql:3306` o `mongo:27017`, si esos servicios están activos. No necesita activar `enviroment/activate.sh` para el PHP del contenedor. La imagen de la aplicación debe declarar una versión de PHP compatible con sus dependencias. Mantenga su Dockerfile, Compose, variables y comandos de despliegue en el repositorio de la aplicación.

## Reglas de ramas y cambios

- Nunca haga commits directos en `main` ni en `develop`, y nunca abra un PR cuyo destino sea `main` o `develop`. Revise la rama actual y la rama destino antes de publicar cambios. Trabaje en una rama de tarea y dirija el PR a la rama de integración autorizada para ese repositorio; para esta infraestructura, use la rama de trabajo de esta línea de desarrollo o la que indique su responsable.
- Aplique la regla por separado en esta infraestructura y en cada repositorio dentro de `repositorios/`. No confunda sus historiales Git ni agregue esos repositorios como submódulos.
- Revise `git status` y el diff antes de cada commit. No incluya `.env`, llaves, tokens, datos reales, datos generados de `storage/`, `vendor/` ni `node_modules/`. Si se expone un secreto, retírelo del cambio y rótelo; borrarlo del último commit no revoca la credencial.
- `update-local.sh` avanza la rama actual de cada repositorio según su upstream. No lo use como sustituto de la revisión de ramas. `--force` descarta cambios y archivos locales sin seguimiento.

## Organización MVC en Laravel

Siga la estructura existente de cada aplicación. En un proyecto Laravel 8 típico:

| Responsabilidad | Ubicación habitual | Regla |
| --- | --- | --- |
| Rutas | `routes/web.php` o `routes/api.php` | Declare método, URI, middleware y controlador; mantenga las rutas pequeñas. |
| Controladores | `app/Http/Controllers/` | Coordine la solicitud y respuesta; delegue reglas de negocio extensas a clases de la aplicación. |
| Validación | `app/Http/Requests/` | Valide y autorice datos de entrada antes de persistirlos. |
| Modelos | `app/Models/` | Defina relaciones, conversiones y atributos asignables; evite lógica de presentación. |
| Vistas | `resources/views/` | Presente datos con Blade; no consulte la base de datos ni aplique permisos solo en la vista. |
| Datos | `database/migrations/`, `database/seeders/` | Versione cambios de esquema y use datos ficticios para desarrollo. |
| Permisos | `app/Policies/` cuando exista o sea necesario | Autorice operaciones sobre cada recurso desde la aplicación. |

Si una regla de negocio no cabe con claridad en un controlador o modelo, la aplicación puede crear una clase de servicio propia. No agregue esa lógica a este repositorio de infraestructura. Acompañe los cambios de rutas, permisos y datos con pruebas unitarias o de funcionalidad en `tests/`.

## Controles de seguridad para la aplicación

- **Entrada y permisos:** use `FormRequest` o validación equivalente, aplique autenticación y autorice cada operación sobre el recurso con Policies o Gates. Compruebe también el caso de acceso denegado; ocultar un botón en Blade no impide una petición directa. [Validación](https://laravel.com/docs/8.x/validation), [autorización](https://laravel.com/docs/8.x/authorization).
- **Persistencia:** persista solo campos validados y esperados. Defina explícitamente `$fillable` o proteja campos sensibles con `$guarded`; no entregue todo `$request->all()` a `create()` o `update()`. Use Eloquent o parámetros enlazados para consultas SQL y evite concatenar entrada en SQL. [Eloquent](https://laravel.com/docs/8.x/eloquent), [base de datos](https://laravel.com/docs/8.x/database).
- **Sesiones y salida:** mantenga el middleware CSRF en rutas web y use `@csrf` en formularios que modifican datos. Renderice datos no confiables con `{{ }}`; permita HTML sin escapar solo tras una revisión específica. Para producción, configure HTTPS y cookies de sesión seguras conforme al despliegue de esa aplicación. [CSRF](https://laravel.com/docs/8.x/csrf), [Blade](https://laravel.com/docs/8.x/blade).
- **Archivos y servicios:** valide tipo, tamaño y autorización de cada carga. Mantenga privados los archivos sensibles y verifique permisos también al descargarlos. No exponga credenciales de MinIO, SQL ni RabbitMQ al navegador. Limite CORS y las instrucciones de carga directa a los orígenes y objetos necesarios. [Almacenamiento](https://laravel.com/docs/8.x/filesystem), [carga directa](direct-upload-architecture.md).
- **Dependencias y secretos:** revise avisos de `composer audit` con una versión de Composer que lo admita; trate los hallazgos como tareas de actualización. Nunca registre secretos, tokens, contraseñas ni datos personales en logs o capturas. Configure `APP_DEBUG=false` fuera del desarrollo local. [Composer audit](https://getcomposer.org/doc/03-cli.md#audit), [despliegue Laravel 8](https://laravel.com/docs/8.x/deployment).

## Antes de un despliegue de producción

Esta infraestructura y `php artisan serve` son para desarrollo local. El repositorio de la aplicación debe definir su propio proceso de producción: versión de PHP y framework soportadas, dependencias bloqueadas, pruebas y revisión de avisos, secretos gestionados fuera de Git, `APP_DEBUG=false`, HTTPS, servidor web con raíz en `public/`, migraciones revisadas, respaldo y recuperación de datos, y operación de colas y tareas programadas si se usan. Mientras una aplicación permanezca en Laravel 8, su soporte de seguridad vencido requiere un plan de actualización antes de considerarla lista para producción. [Guía oficial de despliegue](https://laravel.com/docs/8.x/deployment).
