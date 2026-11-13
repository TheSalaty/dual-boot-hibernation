import Gio from 'gi://Gio'
import { gettext as _, Extension } from 'resource:///org/gnome/shell/extensions/extension.js'
import * as Main from 'resource:///org/gnome/shell/ui/main.js'
import * as PopupMenu from 'resource:///org/gnome/shell/ui/popupMenu.js'

/** Installed by install.sh; does the actual work (see docs/how-it-works.md). */
const OS_SWITCH = '/usr/local/bin/os-switch'

/**
 * The built-in power-menu entries can only be identified by their (localized)
 * label — GNOME Shell exposes no stable, language-independent API for them.
 * Add the labels for your language here if hiding stops working after a locale
 * change. Matching is case-insensitive substring.
 */
const MATCHERS: Record<string, string[]> = {
  'hide-suspend': ['bereitschaft', 'suspend', 'suspender', 'veille'],
  'hide-restart': ['neustart', 'restart', 'reiniciar', 'redémarrer'],
  'hide-poweroff': ['ausschalten', 'power off', 'desligar', 'apagar', 'éteindre'],
  'hide-logout': ['abmelden', 'log out', 'encerrar sessão', 'cerrar sesión', 'fermer la session'],
}

/** A single row inside the system power menu. */
interface MenuItemLike {
  label?: { text?: string }
  visible: boolean
}

/** The private power-menu object we reach into (untyped in the public API). */
interface PowerMenu {
  connect: (signal: string, cb: (menu: unknown, open: boolean) => void) => number
  disconnect: (id: number) => void
  addMenuItem: (item: PopupMenu.PopupMenuItem, position?: number) => void
  _getMenuItems: () => MenuItemLike[]
}

export default class HibernateWindowsExtension extends Extension {
  private _settings?: Gio.Settings
  private _menu?: PowerMenu
  private _winItem?: PopupMenu.PopupMenuItem
  private _hibItem?: PopupMenu.PopupMenuItem
  private _rebootItem?: PopupMenu.PopupMenuItem
  private _ownItems: PopupMenu.PopupMenuItem[] = []
  private _settingsId = 0
  private _openId = 0

  override enable(): void {
    this._settings = this.getSettings()

    this._menu = this._findPowerMenu()
    if (!this._menu) {
      logError(
        new Error(
          'hibernate-windows: power menu not found '
          + '(quickSettings._system._systemItem.menu) — the GNOME API may have changed.',
        ),
      )
      return
    }

    this._winItem = new PopupMenu.PopupMenuItem(_('Hibernate → Windows'))
    this._winItem.connect('activate', () => this._spawn([OS_SWITCH, 'windows']))

    this._rebootItem = new PopupMenu.PopupMenuItem(_('Restart → Windows'))
    this._rebootItem.connect('activate', () => this._spawn([OS_SWITCH, 'reboot-windows']))

    this._hibItem = new PopupMenu.PopupMenuItem(_('Hibernate'))
    this._hibItem.connect('activate', () => this._spawn([OS_SWITCH, 'hibernate']))

    this._menu.addMenuItem(this._hibItem, 0)
    this._menu.addMenuItem(this._rebootItem, 0)
    this._menu.addMenuItem(this._winItem, 0)
    this._ownItems.push(this._winItem, this._rebootItem, this._hibItem)

    this._settingsId = this._settings.connect('changed', () => this._apply())
    this._openId = this._menu.connect('open-state-changed', (_menu, open) => {
      if (open)
        this._apply()
    })

    this._apply()
  }

  override disable(): void {
    if (this._menu && this._openId)
      this._menu.disconnect(this._openId)
    if (this._settings && this._settingsId)
      this._settings.disconnect(this._settingsId)

    // Restore any built-in entries we may have hidden, so uninstalling/disabling
    // never leaves the user with a permanently missing power option.
    if (this._menu) {
      for (const item of this._menu._getMenuItems()) {
        if (this._isOwn(item))
          continue
        const text = item.label?.text?.toLowerCase()
        if (!text)
          continue
        if (Object.values(MATCHERS).some((needles) => needles.some((n) => text.includes(n))))
          item.visible = true
      }
    }

    for (const item of this._ownItems)
      item.destroy()

    this._ownItems = []
    this._winItem = undefined
    this._rebootItem = undefined
    this._hibItem = undefined
    this._menu = undefined
    this._settings = undefined
    this._openId = 0
    this._settingsId = 0
  }

  /** Apply the current settings to our own entries and the built-in ones. */
  private _apply(): void {
    if (!this._menu || !this._settings || !this._winItem || !this._hibItem || !this._rebootItem)
      return

    this._winItem.visible = this._settings.get_boolean('show-hibernate-windows')
    this._rebootItem.visible = this._settings.get_boolean('show-reboot-windows')
    this._hibItem.visible = this._settings.get_boolean('show-hibernate')

    for (const item of this._menu._getMenuItems()) {
      if (this._isOwn(item))
        continue
      const text = item.label?.text?.toLowerCase()
      if (!text)
        continue
      for (const [key, needles] of Object.entries(MATCHERS)) {
        if (needles.some((n) => text.includes(n))) {
          item.visible = !this._settings.get_boolean(key)
          break
        }
      }
    }
  }

  private _isOwn(item: MenuItemLike): boolean {
    return this._ownItems.includes(item as unknown as PopupMenu.PopupMenuItem)
  }

  /** Locate the private power menu inside the Quick Settings area. */
  private _findPowerMenu(): PowerMenu | undefined {
    const statusArea = Main.panel.statusArea as unknown as Record<string, unknown>
    const quickSettings = statusArea.quickSettings as
      | { _system?: { _systemItem?: { menu?: PowerMenu } } }
      | undefined
    return quickSettings?._system?._systemItem?.menu
  }

  /** Fire-and-forget a command; never let a spawn error crash the shell. */
  private _spawn(argv: string[]): void {
    try {
      Gio.Subprocess.new(argv, Gio.SubprocessFlags.NONE)
    }
    catch (err) {
      logError(err as Error, 'hibernate-windows: could not start command')
    }
  }
}
