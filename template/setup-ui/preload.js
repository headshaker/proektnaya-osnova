'use strict'

const { contextBridge, ipcRenderer } = require('electron')

contextBridge.exposeInMainWorld('projectSetup', Object.freeze({
  getDefaults: () => ipcRenderer.invoke('setup:get-defaults'),
  inspectTools: payload => ipcRenderer.invoke('setup:inspect-tools', payload),
  preview: payload => ipcRenderer.invoke('setup:preview', payload),
  apply: payload => ipcRenderer.invoke('setup:apply', payload),
  setLocalSync: enabled => ipcRenderer.invoke('setup:set-local-sync', enabled),
  openLocalSyncLog: () => ipcRenderer.invoke('setup:open-local-sync-log'),
  openHome: () => ipcRenderer.invoke('setup:open-home'),
  openGuide: guideId => ipcRenderer.invoke('setup:open-guide', guideId),
  openProjectGuide: guideId => ipcRenderer.invoke('setup:open-project-guide', guideId),
  openObsidian: () => ipcRenderer.invoke('setup:open-obsidian')
}))
