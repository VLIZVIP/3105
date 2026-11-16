# VLIZ VIP · prueba con base 3106 3.2.5

IPA compilado correctamente, SIN FIRMAR y SIN PRUEBA EN IPHONE.

Se conserva la interfaz VLIZ VIP, el login Zentry, la configuración de autenticación y del catálogo de VLIZ_VIP_IOS.ipa, el identificador de la app, el catálogo con contraseña, los avisos, los recursos de marca y las preferencias de apariencia. Los archivos de login, identidad del dispositivo y almacenamiento de sesión coinciden byte por byte con el código local original. Los servicios subyacentes proceden de la base 3106; no se trasplantó su interfaz completa.

La compilación fue exitosa en GitHub Actions. verification.json registra las comprobaciones del paquete. Esto no demuestra acceso funcional a archivos en iOS 27.2 ni valida el login con una licencia real.

## Firma e instalación

- Firma el IPA con un perfil válido. Para iOS 26.7+/27.x, la firma debe incluir un App Group admitido por el perfil; VLIZ-VIP.entitlements contiene la declaración del proyecto, cuyo grupo debe ajustarse al perfil real.
- Conserva la identidad de firma y el identificador de la app para mantener acceso a sus datos y llavero. La conservación de una sesión existente depende también de la firma.
- Esta prueba usa el mismo identificador que el IPA original: la instalación puede reemplazarlo. Conserva una copia/exportación de tus parches antes de instalar.

## Validación pendiente en el dispositivo

1. Apertura y login Zentry con tu licencia.
2. Carga del catálogo y de avisos.
3. Descarga/desbloqueo de un parche de prueba; aplicación y restauración en datos recuperables.
4. Acceso a Archivos mediante el gesto existente.
5. Persistencia de preferencias y sesión al volver a abrir la app.

El IPA original, la rama main y el catálogo de distribución no se modificaron. La prueba está en experiment/vliz-3106-20261116 del repositorio privado VLIZVIP/3105-zentry-ios.
