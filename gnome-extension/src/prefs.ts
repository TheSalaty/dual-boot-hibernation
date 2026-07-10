import Adw from 'gi://Adw'
import Gio from 'gi://Gio'
import {
  gettext as _,
  ExtensionPreferences,
} from 'resource:///org/gnome/Shell/Extensions/js/extensions/prefs.js'

export default class HibernateWindowsPrefs extends ExtensionPreferences {
  override async fillPreferencesWindow(window: Adw.PreferencesWindow): Promise<void> {
    const settings = this.getSettings()

    const page = new Adw.PreferencesPage({
      title: _('Entries'),
      iconName: 'system-shutdown-symbolic',
    })

    const own = new Adw.PreferencesGroup({
      title: _('Custom entries'),
      description: _('Extra entries added to the power menu'),
    })
    own.add(this._switch(settings, 'show-hibernate-windows', _('Hibernate → Windows')))
    own.add(this._switch(settings, 'show-hibernate', _('Hibernate')))
    page.add(own)

    const std = new Adw.PreferencesGroup({
      title: _('Hide default entries'),
      description: _('Hide the built-in power-menu entries you don’t need'),
    })
    std.add(this._switch(settings, 'hide-suspend', _('Hide Suspend')))
    std.add(this._switch(settings, 'hide-restart', _('Hide Restart')))
    std.add(this._switch(settings, 'hide-poweroff', _('Hide Power Off')))
    std.add(this._switch(settings, 'hide-logout', _('Hide Log Out')))
    page.add(std)

    window.add(page)
  }

  private _switch(settings: Gio.Settings, key: string, title: string): Adw.SwitchRow {
    const row = new Adw.SwitchRow({ title })
    settings.bind(key, row, 'active', Gio.SettingsBindFlags.DEFAULT)
    return row
  }
}
