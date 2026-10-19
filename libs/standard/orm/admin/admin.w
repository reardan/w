# w-orm admin (unit U5.1, docs/projects/orm/u5_1.md): a Django-style
# admin over registered models, mounted on a U4.3 router.
#
#   orm_admin_site* site = orm_admin_site_new()
#   orm_admin_register(site, Book_desc()).list_display(c"title,author,status").search_fields(c"title")
#   orm_admin_mount(site, router, c"/admin/")
#
# The app must run U4.3's db, session, auth and CSRF middleware
# (libs/standard/orm/web/middleware.w). Templates are read from
# libs/standard/orm/admin/templates relative to the working directory
# (orm_admin_site_templates to move them).
import libs.standard.orm.admin.views
